/**
 * Apex service backing the member-facing promo code apply flow at checkout.
 *
 * Public surface (all @AuraEnabled, all 'with sharing' — runs in the member's user context):
 *   apply(orderId, codes)              — Validate + reserve usage; returns per-code results.
 *   remove(orderId, applicationGroupId) — Release a previously-applied group's reservations.
 *   revalidateAll(orderId)             — Re-validate currently-Pending codes before Place Order.
 *
 * Apply orchestration (see docs/promo-code/checkout-apply-flow.md §4.2):
 *   1. Resolve order context (Order + AccountId + Region + Primary_Type + CurrencyIsoCode +
 *      OrderItems with Product2.Family/Name + UnitPrice + Quantity).
 *   2. Fetch Promo_Code__c records for submitted codes filtered by the cart's currency.
 *   3. Run each code through PromoCodeValidator (9 ordered checks; first failure short-circuits).
 *   4. Run PromoCodeAllocationEngine over the valid set to compute per-line adjustments.
 *   5. Single-transaction reservation (Savepoint-wrapped):
 *        a. Release any existing Pending PCIs for this Order (Reason='Reapplied').
 *        b. Insert one Pending PCI per (OrderItem × code) allocation.
 *        c. Update Order.Promo_Codes_Entered__c CSV with the submitted code list.
 *
 * Application_Group_Id__c interpretation:
 *   Per the design doc §4.2 step 4, all PCIs created in one Apply event share the SAME
 *   Application_Group_Id__c. Remove(applicationGroupId) releases all PCIs in that group. To
 *   remove a single code while keeping others, the LWC re-calls apply() with the smaller code
 *   list — Apply's step 5a releases the prior group and step 5b inserts a fresh one with a new
 *   group ID. This keeps the data model simple at the cost of one extra DML cycle per
 *   single-code remove. (Flagged as a design ambiguity in the Phase A2 report.)
 *
 * Currency handling:
 *   The service assumes a multi-currency org and filters Promo_Code__c records by both Code__c
 *   and CurrencyIsoCode. In a single-currency org, the CurrencyIsoCode filter is a no-op and the
 *   service degrades gracefully.
 *
 * Sharing model:
 *   'with sharing' — the running user must have read on Promo_Code__c, create/read/update on
 *   Promo_Code_Item__c, and update on Order.Promo_Codes_Entered__c. The
 *   Customer_Community_Place_Order permission set is the canonical grant for community members.
 */
public with sharing class PromoCodeApplyService {
  // --- Error-code constants (mirrored in PromoCodeValidator) ---
  public static final String ERR_NOT_FOUND = 'NOT_FOUND';
  public static final String ERR_NOT_ACTIVE = 'NOT_ACTIVE';
  public static final String ERR_OUT_OF_WINDOW = 'OUT_OF_WINDOW';
  public static final String ERR_USAGE_EXCEEDED = 'USAGE_EXCEEDED';
  public static final String ERR_MEMBER_LIMIT_EXCEEDED = 'MEMBER_LIMIT_EXCEEDED';
  public static final String ERR_REGION_INELIGIBLE = 'REGION_INELIGIBLE';
  public static final String ERR_ACCOUNT_INELIGIBLE = 'ACCOUNT_INELIGIBLE';
  public static final String ERR_NOT_APPLICABLE_TO_CART = 'NOT_APPLICABLE_TO_CART';
  public static final String ERR_NOT_COMBINABLE = 'NOT_COMBINABLE';
  public static final String ERR_FLOW_NOT_APPLICABLE = 'FLOW_NOT_APPLICABLE';
  public static final String ERR_MEMBER_RECENTLY_ACTIVE = 'MEMBER_RECENTLY_ACTIVE';

  // Canonical flow-type tokens. Order.Flow_Type__c picklist mirrors these. The validator
  // treats null/blank as FLOW_JOIN — the design doc records this as a backward-compat default.
  public static final String FLOW_JOIN = 'Join';
  public static final String FLOW_RENEW = 'Renew';

  // ============================================================
  // DTOs
  // ============================================================

  public class ApplyResult {
    @AuraEnabled
    public List<CodeResult> codeResults;
    @AuraEnabled
    public Decimal totalAdjustment;
    @AuraEnabled
    public Boolean repriceRequired;
    @AuraEnabled
    public String applicationGroupId;
  }

  public class CodeResult {
    @AuraEnabled
    public String code;
    @AuraEnabled
    public String currencyIsoCode;
    @AuraEnabled
    public Boolean valid;
    @AuraEnabled
    public Decimal appliedAmount;
    @AuraEnabled
    public List<Id> appliedToOrderItemIds;
    @AuraEnabled
    public String errorCode;
    @AuraEnabled
    public String errorMessage;
    @AuraEnabled
    public String displayName;
  }

  /**
   * In-memory snapshot of the cart used by the validator and allocation engine. Built once per
   * service entry point so downstream code is pure compute and unit-testable without re-querying.
   */
  public class OrderContext {
    public Id orderId;
    public Id accountId;
    public String currencyIsoCode;
    public String region;
    public List<OrderItem> orderItems;
    // Flow context for Applicable_To__c + Min_Months_Since_Last_Active__c validation rules.
    public String flowType; // 'Join' | 'Renew'; null/blank treated as 'Join'.
    public Date lastActiveMembershipDate; // Account.Last_Active_Membership_Date__c at apply time.

    public Boolean isMultiCurrency() {
      return currencyIsoCode != null;
    }
  }

  // ============================================================
  // Public API
  // ============================================================

  /**
   * Validate the submitted codes against the cart and, for the codes that pass, reserve usage
   * by inserting Pending Promo_Code_Item__c records.
   *
   * @param orderId  the cart Order. Must exist and the running user must have read access.
   * @param codes    list of submitted code strings. Duplicates in the input are deduped
   *                 case-insensitively before processing; whitespace is trimmed; empties are
   *                 ignored.
   * @return ApplyResult with one CodeResult per (deduped) submitted code plus a summary.
   */
  @AuraEnabled
  public static ApplyResult apply(Id orderId, List<String> codes) {
    return apply(orderId, codes, null);
  }

  /**
   * Apply overload that lets the caller explicitly declare the cart's flow type. Resolution
   * order for the flow context used by the validator:
   *   1. flowTypeOverride parameter (when non-blank)
   *   2. Order.Flow_Type__c (set by the originating LWC at cart create)
   *   3. Default to FLOW_JOIN ('Join') — current Phase-1 reality is Join-only.
   */
  @AuraEnabled
  public static ApplyResult apply(
    Id orderId,
    List<String> codes,
    String flowTypeOverride
  ) {
    if (orderId == null) {
      throw new AuraHandledException('Order Id is required.');
    }

    ApplyResult result = new ApplyResult();
    result.codeResults = new List<CodeResult>();
    result.totalAdjustment = 0;
    result.repriceRequired = false;

    List<String> normalizedCodes = normalizeCodeList(codes);
    if (normalizedCodes.isEmpty()) {
      return result;
    }

    OrderContext ctx = loadOrderContext(orderId);
    ctx.flowType = resolveFlowType(flowTypeOverride, ctx.flowType);

    Map<String, Promo_Code__c> codeToParent = fetchPromoCodes(
      normalizedCodes,
      ctx.currencyIsoCode
    );
    Set<Id> parentIds = new Set<Id>();
    for (Promo_Code__c p : codeToParent.values())
      parentIds.add(p.Id);

    UsageCounts usage = PromoCodeValidator.fetchUsageCounts(
      parentIds,
      ctx.accountId
    );

    List<Promo_Code__c> validParents = new List<Promo_Code__c>();
    for (String submitted : normalizedCodes) {
      Promo_Code__c parent = codeToParent.get(submitted.toUpperCase());
      CodeResult cr = PromoCodeValidator.validate(
        submitted,
        parent,
        ctx,
        validParents,
        usage
      );
      result.codeResults.add(cr);
      if (cr.valid) {
        validParents.add(parent);
      }
    }

    // Allocate adjustments across qualifying lines.
    List<PromoCodeAllocationEngine.CodeAllocation> allocations = PromoCodeAllocationEngine.allocate(
      validParents,
      ctx.orderItems
    );

    // Sum per-code totals for the response.
    Map<Id, Decimal> totalByPromoCode = new Map<Id, Decimal>();
    Map<Id, List<Id>> linesByPromoCode = new Map<Id, List<Id>>();
    for (PromoCodeAllocationEngine.CodeAllocation a : allocations) {
      Decimal running = totalByPromoCode.get(a.promoCodeId);
      totalByPromoCode.put(
        a.promoCodeId,
        (running == null ? 0 : running) + a.adjustmentAmount
      );
      List<Id> lines = linesByPromoCode.get(a.promoCodeId);
      if (lines == null) {
        lines = new List<Id>();
        linesByPromoCode.put(a.promoCodeId, lines);
      }
      lines.add(a.orderItemId);
    }

    // Back-fill applied amounts onto valid CodeResults; if a valid code allocated zero (no
    // qualifying lines in the as-applied set), downgrade it to NOT_APPLICABLE_TO_CART so the
    // member sees a clear error rather than a silent zero. This catches edge cases where the
    // validator's step 9 passed but a later code in the set consumed the only qualifying line.
    for (CodeResult cr : result.codeResults) {
      if (!cr.valid)
        continue;
      Promo_Code__c parent = codeToParent.get(cr.code.toUpperCase());
      Decimal codeTotal = totalByPromoCode.get(parent.Id);
      if (codeTotal == null || codeTotal <= 0) {
        cr.valid = false;
        cr.errorCode = ERR_NOT_APPLICABLE_TO_CART;
        cr.errorMessage = PromoCodeValidator.messageFor(
          ERR_NOT_APPLICABLE_TO_CART,
          parent,
          ctx
        );
        continue;
      }
      cr.appliedAmount = codeTotal;
      cr.appliedToOrderItemIds = linesByPromoCode.get(parent.Id);
      result.totalAdjustment += codeTotal;
    }

    // Filter allocations whose code got downgraded above.
    Set<Id> stillValidPromoCodeIds = new Set<Id>();
    for (CodeResult cr : result.codeResults) {
      if (cr.valid) {
        stillValidPromoCodeIds.add(codeToParent.get(cr.code.toUpperCase()).Id);
      }
    }
    List<PromoCodeAllocationEngine.CodeAllocation> finalAllocations = new List<PromoCodeAllocationEngine.CodeAllocation>();
    for (PromoCodeAllocationEngine.CodeAllocation a : allocations) {
      if (stillValidPromoCodeIds.contains(a.promoCodeId))
        finalAllocations.add(a);
    }

    if (finalAllocations.isEmpty()) {
      // No valid codes — still persist the entered list (the LWC keeps invalid codes around
      // so the member can correct them).
      updatePromoCodesEnteredCsv(orderId, normalizedCodes);
      result.repriceRequired = false;
      return result;
    }

    String applicationGroupId = generateUuid();
    reserveUsage(orderId, applicationGroupId, finalAllocations, ctx);
    updatePromoCodesEnteredCsv(orderId, normalizedCodes);

    result.applicationGroupId = applicationGroupId;
    result.repriceRequired = true;
    return result;
  }

  /**
   * Release a previously-applied reservation group. Removes the released codes from
   * Order.Promo_Codes_Entered__c so the cart state stays consistent.
   *
   * @param orderId            the cart Order.
   * @param applicationGroupId the UUID stamped on the PCIs at Apply.
   * @return ApplyResult summarizing remaining state. codeResults is empty; repriceRequired is
   *         true if any PCIs were released (the caller should re-price).
   */
  @AuraEnabled
  public static ApplyResult remove(Id orderId, String applicationGroupId) {
    if (orderId == null) {
      throw new AuraHandledException('Order Id is required.');
    }
    if (String.isBlank(applicationGroupId)) {
      throw new AuraHandledException('Application Group Id is required.');
    }

    ApplyResult result = new ApplyResult();
    result.codeResults = new List<CodeResult>();
    result.totalAdjustment = 0;
    result.repriceRequired = false;

    List<Promo_Code_Item__c> pcis = [
      SELECT Id, Status__c, Promo_Code__r.Code__c
      FROM Promo_Code_Item__c
      WHERE
        Order_Item__r.OrderId = :orderId
        AND Application_Group_Id__c = :applicationGroupId
        AND Status__c = 'Pending'
    ];

    if (pcis.isEmpty()) {
      return result;
    }

    Set<String> removedCodes = new Set<String>();
    for (Promo_Code_Item__c pci : pcis) {
      pci.Status__c = 'Released';
      pci.Released_Date__c = System.now();
      pci.Release_Reason__c = 'Code Removed';
      if (pci.Promo_Code__r != null && pci.Promo_Code__r.Code__c != null) {
        removedCodes.add(pci.Promo_Code__r.Code__c.toUpperCase());
      }
    }

    Savepoint sp = Database.setSavepoint();
    try {
      update pcis;
      rebuildPromoCodesEnteredCsv(orderId, removedCodes);
    } catch (DmlException e) {
      Database.rollback(sp);
      throw new AuraHandledException(
        'Failed to remove promo code: ' + e.getMessage()
      );
    }

    result.repriceRequired = true;
    return result;
  }

  /**
   * Re-validate all currently-Pending codes on an Order against fresh data. Used by the parent
   * Checkout LWC immediately before invoking Place Sales Transaction as a defensive guard
   * against codes that have expired or been deactivated mid-session.
   *
   * @param orderId the cart Order.
   * @return one CodeResult per unique Pending parent code. Codes whose state has changed
   *         (expired, deactivated, etc.) come back with valid=false and the relevant errorCode.
   */
  @AuraEnabled
  public static List<CodeResult> revalidateAll(Id orderId) {
    return revalidateAll(orderId, null);
  }

  @AuraEnabled
  public static List<CodeResult> revalidateAll(
    Id orderId,
    String flowTypeOverride
  ) {
    if (orderId == null) {
      throw new AuraHandledException('Order Id is required.');
    }

    OrderContext ctx = loadOrderContext(orderId);
    ctx.flowType = resolveFlowType(flowTypeOverride, ctx.flowType);

    // Collect unique parent codes from current Pending PCIs.
    List<Promo_Code_Item__c> pendingPcis = [
      SELECT Promo_Code__c
      FROM Promo_Code_Item__c
      WHERE Order_Item__r.OrderId = :orderId AND Status__c = 'Pending'
    ];
    Set<Id> parentIds = new Set<Id>();
    for (Promo_Code_Item__c pci : pendingPcis)
      parentIds.add(pci.Promo_Code__c);

    List<CodeResult> out = new List<CodeResult>();
    if (parentIds.isEmpty()) {
      return out;
    }

    List<Promo_Code__c> parents = [
      SELECT
        Id,
        Code__c,
        CurrencyIsoCode,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c,
        Specific_Products__c,
        Application_Level__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id IN :parentIds
    ];

    UsageCounts usage = PromoCodeValidator.fetchUsageCounts(
      parentIds,
      ctx.accountId
    );

    List<Promo_Code__c> validSoFar = new List<Promo_Code__c>();
    for (Promo_Code__c parent : parents) {
      CodeResult cr = PromoCodeValidator.validate(
        parent.Code__c,
        parent,
        ctx,
        validSoFar,
        usage
      );
      out.add(cr);
      if (cr.valid) {
        validSoFar.add(parent);
      }
    }
    return out;
  }

  /**
   * Loads the currently-applied promo codes on an Order so a host LWC can populate its UI
   * without re-running the apply flow. Returns an `ApplyResult`-shaped payload that mirrors
   * the response of `apply()` — same field names, same structure — so the LWC can consume it
   * with no extra mapping. Each `CodeResult` is `valid=true` with `appliedAmount` equal to the
   * sum of `Applied_Discount_Amount__c` across all Pending PCIs tied to that parent code on
   * this Order. `applicationGroupId` is the most-recent group on the Order.
   *
   * Used by the `promoCodeEntry` LWC on `connectedCallback` when placed on an Order record
   * page (internal Lightning Experience) so that staff can see + manage codes the same way
   * members do in checkout.
   *
   * @param orderId the Order being inspected.
   * @return ApplyResult with codeResults populated for all currently-Pending codes.
   */
  @AuraEnabled
  public static ApplyResult getCurrentlyApplied(Id orderId) {
    ApplyResult result = new ApplyResult();
    result.codeResults = new List<CodeResult>();
    result.totalAdjustment = 0;
    result.repriceRequired = false;
    if (orderId == null) {
      return result;
    }

    List<Promo_Code_Item__c> pendingPcis = [
      SELECT
        Id,
        Promo_Code__c,
        Promo_Code__r.Code__c,
        Promo_Code__r.Display_Name__c,
        Promo_Code__r.CurrencyIsoCode,
        Applied_Discount_Amount__c,
        Application_Group_Id__c,
        Order_Item__c,
        Applied_Date__c
      FROM Promo_Code_Item__c
      WHERE Order_Item__r.OrderId = :orderId AND Status__c = 'Pending'
      ORDER BY Applied_Date__c ASC
    ];
    if (pendingPcis.isEmpty()) {
      return result;
    }

    // Aggregate by parent code: sum applied amounts and collect OrderItem Ids. Preserve the
    // first-seen ordering so the LWC renders codes in the order they were applied.
    Map<Id, CodeResult> byParent = new Map<Id, CodeResult>();
    List<Id> parentOrder = new List<Id>();
    Datetime mostRecentAppliedDate;
    String mostRecentGroupId;

    for (Promo_Code_Item__c pci : pendingPcis) {
      Id parentId = pci.Promo_Code__c;
      CodeResult cr = byParent.get(parentId);
      if (cr == null) {
        cr = new CodeResult();
        cr.code = pci.Promo_Code__r.Code__c;
        cr.displayName = pci.Promo_Code__r.Display_Name__c;
        cr.currencyIsoCode = (String) pci.Promo_Code__r.get('CurrencyIsoCode');
        cr.valid = true;
        cr.appliedAmount = 0;
        cr.appliedToOrderItemIds = new List<Id>();
        byParent.put(parentId, cr);
        parentOrder.add(parentId);
      }
      Decimal amt = pci.Applied_Discount_Amount__c == null
        ? 0
        : pci.Applied_Discount_Amount__c;
      cr.appliedAmount += amt;
      cr.appliedToOrderItemIds.add(pci.Order_Item__c);
      result.totalAdjustment += amt;

      if (
        mostRecentAppliedDate == null ||
        pci.Applied_Date__c > mostRecentAppliedDate
      ) {
        mostRecentAppliedDate = pci.Applied_Date__c;
        mostRecentGroupId = pci.Application_Group_Id__c;
      }
    }

    for (Id parentId : parentOrder) {
      result.codeResults.add(byParent.get(parentId));
    }
    result.applicationGroupId = mostRecentGroupId;
    return result;
  }

  // ============================================================
  // Internals
  // ============================================================

  private static List<String> normalizeCodeList(List<String> raw) {
    List<String> out = new List<String>();
    if (raw == null)
      return out;
    Set<String> seen = new Set<String>();
    for (String s : raw) {
      if (String.isBlank(s))
        continue;
      String trimmed = s.trim();
      String key = trimmed.toUpperCase();
      if (seen.contains(key))
        continue;
      seen.add(key);
      out.add(trimmed);
    }
    return out;
  }

  /**
   * Resolves the cart's flow type for promo validation. Precedence:
   *   explicit caller value > stored Order.Flow_Type__c > default FLOW_JOIN.
   * Returns one of FLOW_JOIN / FLOW_RENEW; never null/blank.
   */
  private static String resolveFlowType(String overrideValue, String stored) {
    if (!String.isBlank(overrideValue)) {
      return overrideValue.trim();
    }
    if (!String.isBlank(stored)) {
      return stored.trim();
    }
    return FLOW_JOIN;
  }

  private static OrderContext loadOrderContext(Id orderId) {
    Boolean isMultiCurrency =
      Schema.getGlobalDescribe().containsKey('CurrencyType') &&
      Schema.SObjectType.Order.fields.getMap().containsKey('currencyisocode');

    String orderSoql =
      'SELECT Id, AccountId, Region__c, Flow_Type__c, ' +
      'Account.Last_Active_Membership_Date__c' +
      (isMultiCurrency ? ', CurrencyIsoCode' : '') +
      ' FROM Order WHERE Id = :orderId LIMIT 1';
    List<SObject> orders = Database.query(orderSoql);
    if (orders.isEmpty()) {
      throw new AuraHandledException(
        'Order not found or not accessible: ' + orderId
      );
    }
    SObject ord = orders[0];

    OrderContext ctx = new OrderContext();
    ctx.orderId = orderId;
    ctx.accountId = (Id) ord.get('AccountId');
    ctx.region = (String) ord.get('Region__c');
    ctx.flowType = (String) ord.get('Flow_Type__c');
    SObject acct = ord.getSObject('Account');
    ctx.lastActiveMembershipDate = acct == null
      ? null
      : (Date) acct.get('Last_Active_Membership_Date__c');
    ctx.currencyIsoCode = isMultiCurrency
      ? (String) ord.get('CurrencyIsoCode')
      : null;

    ctx.orderItems = [
      SELECT
        Id,
        OrderId,
        Product2Id,
        Product2.Name,
        Product2.Family,
        Product2.ProductCode,
        Quantity,
        UnitPrice
      FROM OrderItem
      WHERE OrderId = :orderId
    ];

    return ctx;
  }

  private static Map<String, Promo_Code__c> fetchPromoCodes(
    List<String> codes,
    String currencyIso
  ) {
    Set<String> upperCodes = new Set<String>();
    for (String c : codes)
      upperCodes.add(c.toUpperCase());

    Boolean isMultiCurrency = currencyIso != null;

    String baseSelect =
      'SELECT Id, Code__c, ' +
      (isMultiCurrency ? 'CurrencyIsoCode, ' : '') +
      'Status__c, Display_Name__c, ' +
      'Effective_Start_Date__c, Effective_End_Date__c, ' +
      'Total_Usage_Limit__c, Per_Member_Usage_Limit__c, ' +
      'Member_Type_Scope__c, Region_Scope__c, Account__c, ' +
      'Product_Scope_Type__c, Product_Family_Scope__c, Specific_Products__c, ' +
      'Application_Level__c, ' +
      'Combinable__c, Combination_Group__c, ' +
      'Discount_Type__c, Discount_Value__c, ' +
      'Applicable_To__c, Min_Months_Since_Last_Active__c ' +
      'FROM Promo_Code__c ' +
      'WHERE Code__c IN :upperCodes' +
      (isMultiCurrency ? ' AND CurrencyIsoCode = :currencyIso' : '');

    Map<String, Promo_Code__c> result = new Map<String, Promo_Code__c>();
    for (Promo_Code__c p : (List<Promo_Code__c>) Database.query(baseSelect)) {
      if (p.Code__c != null) {
        result.put(p.Code__c.toUpperCase(), p);
      }
    }
    return result;
  }

  private static void reserveUsage(
    Id orderId,
    String applicationGroupId,
    List<PromoCodeAllocationEngine.CodeAllocation> allocations,
    OrderContext ctx
  ) {
    Savepoint sp = Database.setSavepoint();
    try {
      // 1. Release any existing Pending PCIs for this Order. We mark them rather than delete
      //    to preserve the audit trail of redemption attempts.
      List<Promo_Code_Item__c> existing = [
        SELECT Id
        FROM Promo_Code_Item__c
        WHERE Order_Item__r.OrderId = :orderId AND Status__c = 'Pending'
      ];
      if (!existing.isEmpty()) {
        Datetime now = System.now();
        for (Promo_Code_Item__c pci : existing) {
          pci.Status__c = 'Released';
          pci.Released_Date__c = now;
          pci.Release_Reason__c = 'Reapplied';
        }
        update existing;
      }

      // 2. Insert new Pending PCIs (one per allocation).
      List<Promo_Code_Item__c> toInsert = new List<Promo_Code_Item__c>();
      Datetime appliedDate = System.now();
      for (PromoCodeAllocationEngine.CodeAllocation a : allocations) {
        Promo_Code_Item__c pci = new Promo_Code_Item__c(
          Promo_Code__c = a.promoCodeId,
          Order_Item__c = a.orderItemId,
          Member__c = ctx.accountId,
          Applied_Discount_Amount__c = a.adjustmentAmount,
          Discount_Type_Snapshot__c = a.discountTypeSnapshot,
          Discount_Value_Snapshot__c = a.discountValueSnapshot,
          Application_Level_Snapshot__c = a.applicationLevelSnapshot,
          Product_Scope_Type_Snapshot__c = a.productScopeTypeSnapshot,
          Application_Group_Id__c = applicationGroupId,
          Applied_Date__c = appliedDate,
          Status__c = 'Pending'
        );
        toInsert.add(pci);
      }
      if (!toInsert.isEmpty()) {
        insert toInsert;
      }
    } catch (DmlException e) {
      Database.rollback(sp);
      String msg =
        'Failed to reserve promo code usage: ' +
        (e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage());
      AuraHandledException ex = new AuraHandledException(msg);
      ex.setMessage(msg);
      throw ex;
    }
  }

  /**
   * Persists the comma-separated list of codes the member has entered. Invoked on every Apply
   * regardless of whether codes were valid — the LWC keeps invalid codes visible so the member
   * can correct them, and we want that list to survive navigation away from the cart.
   */
  private static void updatePromoCodesEnteredCsv(
    Id orderId,
    List<String> codes
  ) {
    Order o = new Order(Id = orderId);
    o.Promo_Codes_Entered__c = codes == null || codes.isEmpty()
      ? null
      : String.join(codes, ',');
    update o;
  }

  /**
   * Used by Remove. Removes the just-released codes from the Order's CSV but preserves any
   * other codes the member still has applied (since multiple Apply events can have layered).
   */
  private static void rebuildPromoCodesEnteredCsv(
    Id orderId,
    Set<String> removedCodesUpper
  ) {
    Order o = [
      SELECT Id, Promo_Codes_Entered__c
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (String.isBlank(o.Promo_Codes_Entered__c))
      return;

    List<String> kept = new List<String>();
    for (String token : o.Promo_Codes_Entered__c.split(',')) {
      String trimmed = token.trim();
      if (String.isBlank(trimmed))
        continue;
      if (!removedCodesUpper.contains(trimmed.toUpperCase())) {
        kept.add(trimmed);
      }
    }
    o.Promo_Codes_Entered__c = kept.isEmpty() ? null : String.join(kept, ',');
    update o;
  }

  /**
   * Generates a UUID v4 string for Application_Group_Id__c. Apex has no native UUID type;
   * this uses cryptographic randomness and the standard hyphenated formatting.
   */
  @TestVisible
  private static String generateUuid() {
    Blob b = Crypto.generateAesKey(128);
    String hex = EncodingUtil.convertToHex(b);
    return hex.substring(0, 8) +
      '-' +
      hex.substring(8, 12) +
      '-' +
      '4' +
      hex.substring(13, 16) +
      '-' +
      '8' +
      hex.substring(17, 20) +
      '-' +
      hex.substring(20, 32);
  }

  /**
   * Aggregate Pending + Confirmed usage stats for a set of promo codes, scoped both globally
   * and to a specific member, in a single query each. Used by the validator for rules 4 and 5.
   */
  public class UsageCounts {
    public Map<Id, Integer> pendingByCode = new Map<Id, Integer>();
    public Map<Id, Integer> confirmedByCode = new Map<Id, Integer>();
    public Map<Id, Integer> memberPendingByCode = new Map<Id, Integer>();
    public Map<Id, Integer> memberConfirmedByCode = new Map<Id, Integer>();

    public Integer totalUsed(Id promoCodeId) {
      Integer pending = pendingByCode.containsKey(promoCodeId)
        ? pendingByCode.get(promoCodeId)
        : 0;
      Integer confirmed = confirmedByCode.containsKey(promoCodeId)
        ? confirmedByCode.get(promoCodeId)
        : 0;
      return pending + confirmed;
    }

    public Integer memberUsed(Id promoCodeId) {
      Integer pending = memberPendingByCode.containsKey(promoCodeId)
        ? memberPendingByCode.get(promoCodeId)
        : 0;
      Integer confirmed = memberConfirmedByCode.containsKey(promoCodeId)
        ? memberConfirmedByCode.get(promoCodeId)
        : 0;
      return pending + confirmed;
    }
  }
}
