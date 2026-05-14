/**
 * Stateless validator for promo codes at apply time. Implements the ordered validation rules
 * from docs/promo-code/checkout-apply-flow.md §4.4. Each call returns a structured CodeResult
 * with an explicit errorCode + member-facing errorMessage; the first failing check short-circuits.
 *
 * Rule order:
 *   1. NOT_FOUND               — Code+currency lookup returned no record.
 *   2. NOT_ACTIVE              — Status__c != 'Active'.
 *   3. OUT_OF_WINDOW           — NOW() outside Effective_Start_Date..Effective_End_Date.
 *   4. USAGE_EXCEEDED          — Total_Usage_Limit__c hit (Confirmed + Pending across all members).
 *   5. MEMBER_LIMIT_EXCEEDED   — Per_Member_Usage_Limit__c hit for the current Member.
 *   6. REGION_INELIGIBLE       — Cart's Order.Region__c not in Region_Scope__c.
 *   7. ACCOUNT_INELIGIBLE      — Order.AccountId != Promo_Code__c.Account__c.
 *   7a. FLOW_NOT_APPLICABLE    — Cart flow type (Join/Renew) not in parent.Applicable_To__c.
 *   7b. MEMBER_RECENTLY_ACTIVE — Join flow with Min_Months_Since_Last_Active__c set and the
 *                                Account's Last_Active_Membership_Date__c is more recent than
 *                                the configured lookback (member is too-recently active).
 *   8. NOT_APPLICABLE_TO_CART  — No OrderItem matches Product_Scope_Type__c rules (§5.2).
 *   9. NOT_COMBINABLE          — Conflict with already-validated codes in this Apply set.
 *
 * Note on Member_Type_Scope__c: it is NOT an eligibility gate at the validator level — it's
 * consumed by the allocation engine for product-name CONTAINS matching under
 * Product_Scope_Type__c = 'Specific Membership Types'. Member-eligibility is enforced via
 * Region_Scope__c (rule 6) and the optional Account__c lookup (rule 7).
 *
 * The eligibility check in rule 8 mirrors the allocation engine's Step 1 filter — the validator
 * answers "is at least one line eligible?", the engine then computes the actual per-line math.
 *
 * Combinability rule:
 *   If any code in the validated set has Combinable__c = false, no other code can join it.
 *   Otherwise, every code in the set must share the same Combination_Group__c.
 *
 * The class is stateless and 'with sharing'. Callers (PromoCodeApplyService) are responsible
 * for fetching parent records and usage counts before invoking validate().
 */
public with sharing class PromoCodeValidator {
  public static PromoCodeApplyService.CodeResult validate(
    String submittedCode,
    Promo_Code__c parent,
    PromoCodeApplyService.OrderContext ctx,
    List<Promo_Code__c> alreadyValid,
    PromoCodeApplyService.UsageCounts usage
  ) {
    PromoCodeApplyService.CodeResult cr = new PromoCodeApplyService.CodeResult();
    cr.code = submittedCode == null ? '' : submittedCode.trim();
    cr.appliedToOrderItemIds = new List<Id>();
    cr.currencyIsoCode = ctx == null ? null : ctx.currencyIsoCode;

    // 1. NOT_FOUND
    if (parent == null) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_NOT_FOUND,
        messageFor(PromoCodeApplyService.ERR_NOT_FOUND, null, ctx, cr.code)
      );
    }
    cr.displayName = parent.Display_Name__c;

    // 2. NOT_ACTIVE
    if (parent.Status__c != 'Active') {
      return fail(
        cr,
        PromoCodeApplyService.ERR_NOT_ACTIVE,
        messageFor(PromoCodeApplyService.ERR_NOT_ACTIVE, parent, ctx, cr.code)
      );
    }

    // 3. OUT_OF_WINDOW
    Datetime now = System.now();
    if (
      parent.Effective_Start_Date__c != null &&
      now < parent.Effective_Start_Date__c
    ) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_OUT_OF_WINDOW,
        messageFor(
          PromoCodeApplyService.ERR_OUT_OF_WINDOW,
          parent,
          ctx,
          cr.code
        )
      );
    }
    if (
      parent.Effective_End_Date__c != null &&
      now > parent.Effective_End_Date__c
    ) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_OUT_OF_WINDOW,
        messageFor(
          PromoCodeApplyService.ERR_OUT_OF_WINDOW,
          parent,
          ctx,
          cr.code
        )
      );
    }

    // 4. USAGE_EXCEEDED
    if (parent.Total_Usage_Limit__c != null) {
      Integer totalUsed = usage.totalUsed(parent.Id);
      if (totalUsed >= parent.Total_Usage_Limit__c.intValue()) {
        return fail(
          cr,
          PromoCodeApplyService.ERR_USAGE_EXCEEDED,
          messageFor(
            PromoCodeApplyService.ERR_USAGE_EXCEEDED,
            parent,
            ctx,
            cr.code
          )
        );
      }
    }

    // 5. MEMBER_LIMIT_EXCEEDED
    if (parent.Per_Member_Usage_Limit__c != null) {
      Integer memberUsed = usage.memberUsed(parent.Id);
      if (memberUsed >= parent.Per_Member_Usage_Limit__c.intValue()) {
        return fail(
          cr,
          PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED,
          messageFor(
            PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED,
            parent,
            ctx,
            cr.code
          )
        );
      }
    }

    // 6. REGION_INELIGIBLE
    if (!String.isBlank(parent.Region_Scope__c)) {
      if (!multiPicklistContains(parent.Region_Scope__c, ctx.region)) {
        return fail(
          cr,
          PromoCodeApplyService.ERR_REGION_INELIGIBLE,
          messageFor(
            PromoCodeApplyService.ERR_REGION_INELIGIBLE,
            parent,
            ctx,
            cr.code
          )
        );
      }
    }

    // 7. ACCOUNT_INELIGIBLE
    if (parent.Account__c != null && parent.Account__c != ctx.accountId) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE,
        messageFor(
          PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE,
          parent,
          ctx,
          cr.code
        )
      );
    }

    // 7a. FLOW_NOT_APPLICABLE — cart's flow type must be accepted by the code.
    if (!flowMatches(parent.Applicable_To__c, ctx.flowType)) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
        messageFor(
          PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
          parent,
          ctx,
          cr.code
        )
      );
    }

    // 7b. MEMBER_RECENTLY_ACTIVE — Join + lookback configured + member is too recently active.
    if (
      isJoinFlow(ctx.flowType) &&
      parent.Min_Months_Since_Last_Active__c != null &&
      parent.Min_Months_Since_Last_Active__c > 0 &&
      ctx.lastActiveMembershipDate != null
    ) {
      Integer requiredMonths = parent.Min_Months_Since_Last_Active__c.intValue();
      Integer monthsSince = monthsBetween(
        ctx.lastActiveMembershipDate,
        Date.today()
      );
      if (monthsSince < requiredMonths) {
        return fail(
          cr,
          PromoCodeApplyService.ERR_MEMBER_RECENTLY_ACTIVE,
          messageFor(
            PromoCodeApplyService.ERR_MEMBER_RECENTLY_ACTIVE,
            parent,
            ctx,
            cr.code
          )
        );
      }
    }

    // 8. NOT_APPLICABLE_TO_CART
    if (!hasEligibleLine(parent, ctx.orderItems)) {
      return fail(
        cr,
        PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
        messageFor(
          PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
          parent,
          ctx,
          cr.code
        )
      );
    }

    // Rule 9 (combinability) is no longer evaluated here — it's a cart-wide resolution
    // that runs as a single post-pass in PromoCodeValidator.resolveCombinability() after
    // every code has gone through rules 1-8b. The `alreadyValid` parameter is retained for
    // ABI stability but unused.

    cr.valid = true;
    return cr;
  }

  /**
   * Cart-wide combinability resolution. Runs once after every code has been validated by
   * `validate()`. Mutates the supplied CodeResults in place:
   *
   *   - If 2+ valid codes are Combinable and at least one valid code is non-combinable, the
   *     non-combinables are dropped with errorCode DROPPED_NON_COMBINABLE. The remaining
   *     combinables must share the same Combination_Group__c (first wins; mismatches get
   *     errorCode NOT_COMBINABLE).
   *   - Otherwise (0 or 1 valid combinable), the cart degrades to original "exclusive"
   *     semantics: the first-submitted valid code wins, every subsequent valid code is
   *     marked NOT_COMBINABLE.
   *
   * Codes already failing earlier rules are left alone — combinability only re-classifies
   * codes that are otherwise valid.
   */
  public static void resolveCombinability(
    List<PromoCodeApplyService.CodeResult> codeResults,
    Map<String, Promo_Code__c> codeToParent,
    PromoCodeApplyService.OrderContext ctx
  ) {
    if (codeResults == null || codeResults.isEmpty()) {
      return;
    }
    if (codeToParent == null) {
      codeToParent = new Map<String, Promo_Code__c>();
    }

    List<PromoCodeApplyService.CodeResult> validResults = new List<PromoCodeApplyService.CodeResult>();
    Integer combinableCount = 0;
    for (PromoCodeApplyService.CodeResult cr : codeResults) {
      if (!cr.valid) {
        continue;
      }
      Promo_Code__c parent = parentFor(cr, codeToParent);
      if (parent == null) {
        continue;
      }
      validResults.add(cr);
      if (parent.Combinable__c == true) {
        combinableCount += 1;
      }
    }
    if (validResults.size() <= 1) {
      return; // Nothing to resolve with 0 or 1 valid codes.
    }

    if (combinableCount >= 2) {
      // Drop every non-combinable; enforce group match among the combinables.
      String anchorGroup = null;
      Promo_Code__c anchorCombinable = null;
      for (PromoCodeApplyService.CodeResult cr : validResults) {
        Promo_Code__c parent = parentFor(cr, codeToParent);
        if (parent.Combinable__c != true) {
          cr.valid = false;
          cr.errorCode = PromoCodeApplyService.ERR_DROPPED_NON_COMBINABLE;
          cr.errorMessage = messageFor(
            PromoCodeApplyService.ERR_DROPPED_NON_COMBINABLE,
            parent,
            ctx,
            cr.code
          );
          continue;
        }
        if (anchorCombinable == null) {
          anchorCombinable = parent;
          anchorGroup = parent.Combination_Group__c;
          continue;
        }
        String thisGroup = parent.Combination_Group__c;
        Boolean groupsMatch = (anchorGroup != null &&
        thisGroup != null &&
        anchorGroup.equalsIgnoreCase(thisGroup));
        if (!groupsMatch) {
          cr.valid = false;
          cr.errorCode = PromoCodeApplyService.ERR_NOT_COMBINABLE;
          cr.errorMessage = messageFor(
            PromoCodeApplyService.ERR_NOT_COMBINABLE,
            parent,
            ctx,
            cr.code
          );
        }
      }
    } else {
      // 0 or 1 combinables in the valid set: original exclusive behavior — first valid
      // wins; everything after it is NOT_COMBINABLE.
      Boolean firstClaimed = false;
      for (PromoCodeApplyService.CodeResult cr : validResults) {
        if (!firstClaimed) {
          firstClaimed = true;
          continue;
        }
        Promo_Code__c parent = parentFor(cr, codeToParent);
        cr.valid = false;
        cr.errorCode = PromoCodeApplyService.ERR_NOT_COMBINABLE;
        cr.errorMessage = messageFor(
          PromoCodeApplyService.ERR_NOT_COMBINABLE,
          parent,
          ctx,
          cr.code
        );
      }
    }
  }

  private static Promo_Code__c parentFor(
    PromoCodeApplyService.CodeResult cr,
    Map<String, Promo_Code__c> codeToParent
  ) {
    if (cr.code == null) {
      return null;
    }
    return codeToParent.get(cr.code.toUpperCase());
  }

  /**
   * Aggregate Pending + Confirmed PCI counts across a set of parent codes, in two SOQLs.
   * Used by validation rules 4 (USAGE_EXCEEDED) and 5 (MEMBER_LIMIT_EXCEEDED).
   */
  public static PromoCodeApplyService.UsageCounts fetchUsageCounts(
    Set<Id> promoCodeIds,
    Id memberId
  ) {
    PromoCodeApplyService.UsageCounts uc = new PromoCodeApplyService.UsageCounts();
    if (promoCodeIds == null || promoCodeIds.isEmpty()) {
      return uc;
    }

    for (AggregateResult ar : [
      SELECT Promo_Code__c parentId, Status__c status, COUNT(Id) cnt
      FROM Promo_Code_Item__c
      WHERE
        Promo_Code__c IN :promoCodeIds
        AND Status__c IN ('Pending', 'Confirmed')
      GROUP BY Promo_Code__c, Status__c
    ]) {
      Id parentId = (Id) ar.get('parentId');
      String status = (String) ar.get('status');
      Integer cnt = ((Decimal) ar.get('cnt')).intValue();
      if (status == 'Pending') {
        uc.pendingByCode.put(parentId, cnt);
      } else if (status == 'Confirmed') {
        uc.confirmedByCode.put(parentId, cnt);
      }
    }

    if (memberId != null) {
      for (AggregateResult ar : [
        SELECT Promo_Code__c parentId, Status__c status, COUNT(Id) cnt
        FROM Promo_Code_Item__c
        WHERE
          Promo_Code__c IN :promoCodeIds
          AND Member__c = :memberId
          AND Status__c IN ('Pending', 'Confirmed')
        GROUP BY Promo_Code__c, Status__c
      ]) {
        Id parentId = (Id) ar.get('parentId');
        String status = (String) ar.get('status');
        Integer cnt = ((Decimal) ar.get('cnt')).intValue();
        if (status == 'Pending') {
          uc.memberPendingByCode.put(parentId, cnt);
        } else if (status == 'Confirmed') {
          uc.memberConfirmedByCode.put(parentId, cnt);
        }
      }
    }

    return uc;
  }

  public static String messageFor(
    String errorCode,
    Promo_Code__c parent,
    PromoCodeApplyService.OrderContext ctx
  ) {
    return messageFor(
      errorCode,
      parent,
      ctx,
      parent == null ? '' : parent.Code__c
    );
  }

  /**
   * Renders the member-facing message for an error code. Every string is sourced from
   * a Custom Label so the entire member-facing surface area is translatable via the
   * Translation Workbench. Placeholder substitution uses `{0}`/`{1}` style and
   * String.format() to keep variable text out of the label values themselves.
   */
  public static String messageFor(
    String errorCode,
    Promo_Code__c parent,
    PromoCodeApplyService.OrderContext ctx,
    String submittedCode
  ) {
    if (errorCode == PromoCodeApplyService.ERR_NOT_FOUND) {
      String iso = ctx == null ||
        ctx.currencyIsoCode == null
        ? ''
        : ctx.currencyIsoCode;
      String code = submittedCode == null ? '' : submittedCode;
      return String.isBlank(iso)
        ? String.format(
            System.Label.PromoCodeApply_Err_NotFound,
            new List<String>{ code }
          )
        : String.format(
            System.Label.PromoCodeApply_Err_NotFoundForCurrency,
            new List<String>{ code, iso }
          );
    }
    if (errorCode == PromoCodeApplyService.ERR_NOT_ACTIVE) {
      return System.Label.PromoCodeApply_Err_NotActive;
    }
    if (errorCode == PromoCodeApplyService.ERR_OUT_OF_WINDOW) {
      return outOfWindowMessage(parent);
    }
    if (errorCode == PromoCodeApplyService.ERR_USAGE_EXCEEDED) {
      return System.Label.PromoCodeApply_Err_UsageExceeded;
    }
    if (errorCode == PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED) {
      return System.Label.PromoCodeApply_Err_MemberLimitExceeded;
    }
    if (errorCode == PromoCodeApplyService.ERR_REGION_INELIGIBLE) {
      return System.Label.PromoCodeApply_Err_RegionIneligible;
    }
    if (errorCode == PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE) {
      return System.Label.PromoCodeApply_Err_AccountIneligible;
    }
    if (errorCode == PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART) {
      return System.Label.PromoCodeApply_Err_NotApplicableToCart;
    }
    if (errorCode == PromoCodeApplyService.ERR_NOT_COMBINABLE) {
      return System.Label.PromoCodeApply_Err_NotCombinable;
    }
    if (errorCode == PromoCodeApplyService.ERR_DROPPED_NON_COMBINABLE) {
      return System.Label.PromoCodeApply_Err_DroppedNonCombinable;
    }
    if (errorCode == PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE) {
      String allowed = parent == null ? '' : parent.Applicable_To__c;
      String flow = ctx == null ? '' : ctx.flowType;
      if ('Join'.equalsIgnoreCase(allowed)) {
        return System.Label.PromoCodeApply_Err_FlowNotApplicable_JoinOnly;
      }
      if ('Renew'.equalsIgnoreCase(allowed)) {
        return System.Label.PromoCodeApply_Err_FlowNotApplicable_RenewOnly;
      }
      // Should be unreachable when allowed='Both', but keep a safe fallback.
      String flowWord = String.isBlank(flow)
        ? System.Label.PromoCodeApply_Err_FlowNotApplicable_DefaultFlowWord
        : flow.toLowerCase();
      return String.format(
        System.Label.PromoCodeApply_Err_FlowNotApplicable_Other,
        new List<String>{ flowWord }
      );
    }
    if (errorCode == PromoCodeApplyService.ERR_MEMBER_RECENTLY_ACTIVE) {
      Integer months = (parent != null &&
        parent.Min_Months_Since_Last_Active__c != null)
        ? parent.Min_Months_Since_Last_Active__c.intValue()
        : 0;
      return String.format(
        System.Label.PromoCodeApply_Err_MemberRecentlyActive,
        new List<String>{ String.valueOf(months) }
      );
    }
    return System.Label.PromoCodeApply_Err_Generic;
  }

  /**
   * Pretty-prints the OUT_OF_WINDOW message. If the parent has an effective window
   * defined (either bound set), the date-bearing variant is used; otherwise the
   * bare label fires. Date formatting respects the running user's locale.
   */
  private static String outOfWindowMessage(Promo_Code__c parent) {
    if (
      parent == null ||
      (parent.Effective_Start_Date__c == null &&
      parent.Effective_End_Date__c == null)
    ) {
      return System.Label.PromoCodeApply_Err_OutOfWindow;
    }
    String startDisplay = parent.Effective_Start_Date__c == null
      ? System.Label.PromoCodeApply_EffectiveWindow_AnyTime
      : parent.Effective_Start_Date__c.format();
    String endDisplay = parent.Effective_End_Date__c == null
      ? System.Label.PromoCodeApply_EffectiveWindow_NoEnd
      : parent.Effective_End_Date__c.format();
    return String.format(
      System.Label.PromoCodeApply_Err_OutOfWindow_WithWindow,
      new List<String>{ startDisplay, endDisplay }
    );
  }

  // ============================================================
  // Internals
  // ============================================================

  private static PromoCodeApplyService.CodeResult fail(
    PromoCodeApplyService.CodeResult cr,
    String errorCode,
    String message
  ) {
    cr.valid = false;
    cr.errorCode = errorCode;
    cr.errorMessage = message;
    return cr;
  }

  private static Boolean multiPicklistContains(
    String fieldValue,
    String target
  ) {
    if (String.isBlank(fieldValue) || String.isBlank(target))
      return false;
    for (String v : fieldValue.split(';')) {
      if (v.trim().equalsIgnoreCase(target.trim()))
        return true;
    }
    return false;
  }

  /**
   * Mirrors the allocation engine's Step 1 eligibility filter — returns true if at least one
   * OrderItem in the cart matches the code's Product_Scope_Type__c rule. The engine re-runs the
   * same filter and computes adjustments; the validator only needs a boolean.
   *
   * Kept aligned with PromoCodeAllocationEngine.filterEligible — when scope semantics change,
   * update both.
   */
  private static Boolean hasEligibleLine(
    Promo_Code__c code,
    List<OrderItem> orderItems
  ) {
    if (orderItems == null || orderItems.isEmpty())
      return false;
    String scopeType = code.Product_Scope_Type__c == null
      ? 'All Items'
      : code.Product_Scope_Type__c;

    if (scopeType == 'All Items')
      return true;

    if (scopeType == 'Product Family') {
      Set<String> families = splitMultiPicklist(code.Product_Family_Scope__c);
      for (OrderItem oi : orderItems) {
        if (oi.Product2 == null || oi.Product2.Family == null)
          continue;
        if (families.contains(oi.Product2.Family.toLowerCase()))
          return true;
      }
      return false;
    }
    if (scopeType == 'Specific Membership Types') {
      Set<String> tokens = splitMultiPicklist(code.Member_Type_Scope__c);
      for (OrderItem oi : orderItems) {
        if (oi.Product2 == null || oi.Product2.Name == null)
          continue;
        String nameLc = oi.Product2.Name.toLowerCase();
        for (String t : tokens) {
          if (nameLc.contains(t))
            return true;
        }
      }
      return false;
    }
    if (scopeType == 'Specific Products') {
      Set<String> codes = splitCsv(code.Specific_Products__c);
      for (OrderItem oi : orderItems) {
        if (oi.Product2 == null || oi.Product2.ProductCode == null)
          continue;
        if (codes.contains(oi.Product2.ProductCode.trim().toLowerCase()))
          return true;
      }
      return false;
    }
    return false;
  }

  private static Set<String> splitMultiPicklist(String value) {
    Set<String> out = new Set<String>();
    if (String.isBlank(value))
      return out;
    for (String token : value.split(';')) {
      String t = token == null ? '' : token.trim();
      if (!String.isBlank(t))
        out.add(t.toLowerCase());
    }
    return out;
  }

  private static Set<String> splitCsv(String value) {
    Set<String> out = new Set<String>();
    if (String.isBlank(value))
      return out;
    for (String token : value.split(',')) {
      String t = token == null ? '' : token.trim();
      if (!String.isBlank(t))
        out.add(t.toLowerCase());
    }
    return out;
  }

  private static Boolean isCombinableWith(
    Promo_Code__c candidate,
    List<Promo_Code__c> alreadyValid
  ) {
    if (alreadyValid == null || alreadyValid.isEmpty())
      return true;

    if (candidate.Combinable__c == false)
      return false;

    for (Promo_Code__c existing : alreadyValid) {
      if (existing.Combinable__c == false)
        return false;
    }

    String candidateGroup = candidate.Combination_Group__c;
    if (String.isBlank(candidateGroup)) {
      // Combinable=true with no group — treat as not-combinable. The data-layer VR
      // VR_PromoCode_RequireCombinationGroup should prevent this state at save time.
      return false;
    }
    for (Promo_Code__c existing : alreadyValid) {
      String existingGroup = existing.Combination_Group__c;
      if (
        existingGroup == null || !existingGroup.equalsIgnoreCase(candidateGroup)
      ) {
        return false;
      }
    }
    return true;
  }

  /**
   * Flow-type acceptance check. Null/blank Applicable_To__c is treated as 'Both' so legacy
   * records (created before the field existed) keep working until backfilled.
   */
  private static Boolean flowMatches(String applicableTo, String flowType) {
    String allowed = String.isBlank(applicableTo)
      ? 'Both'
      : applicableTo.trim();
    String flow = String.isBlank(flowType)
      ? PromoCodeApplyService.FLOW_JOIN
      : flowType.trim();
    if ('Both'.equalsIgnoreCase(allowed)) {
      return true;
    }
    return allowed.equalsIgnoreCase(flow);
  }

  private static Boolean isJoinFlow(String flowType) {
    String flow = String.isBlank(flowType)
      ? PromoCodeApplyService.FLOW_JOIN
      : flowType.trim();
    return PromoCodeApplyService.FLOW_JOIN.equalsIgnoreCase(flow);
  }

  /**
   * Full calendar months between two dates (start..end). E.g., Jan 15 -> Feb 14 = 0 months,
   * Jan 15 -> Feb 15 = 1 month. Uses Date.monthsBetween() and adjusts for the day-of-month
   * boundary so "12 or more months ago" lines up with intuitive reading.
   */
  private static Integer monthsBetween(Date start, Date endDate) {
    if (start == null || endDate == null) {
      return 0;
    }
    Integer raw = start.monthsBetween(endDate);
    if (raw <= 0) {
      return raw;
    }
    if (endDate.day() < start.day()) {
      raw -= 1;
    }
    return raw;
  }
}
