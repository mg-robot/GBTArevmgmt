/**
 * Computes per-line discount allocations for a set of validated promo codes against a cart of
 * OrderItems. Pure compute — no DML, no SOQL. Caller (PromoCodeApplyService) is responsible for
 * upstream validation and downstream persistence as Promo_Code_Item__c.
 *
 * Allocation is governed by two fields on the parent Promo_Code__c:
 *   - Application_Level__c   ("Per Order" | "Per Line")
 *   - Product_Scope_Type__c  ("All Items" | "Product Family" | "Specific Membership Types"
 *                             | "Specific Products")
 *
 * Step 1 — eligibility (Product_Scope_Type__c):
 *   All Items                 → every OrderItem in the cart
 *   Product Family            → Product_Family_Scope__c (multi-picklist; semicolon-split)
 *                                ⇒ Product2.Family ∈ selected families
 *   Specific Membership Types → Member_Type_Scope__c (multi-picklist; semicolon-split)
 *                                ⇒ Product2.Name CONTAINS any selected token (case-insensitive)
 *   Specific Products         → Specific_Products__c (CSV of ProductCodes; comma-split)
 *                                ⇒ Product2.ProductCode ∈ list (case-insensitive, trimmed)
 *
 * Step 1.5 — guards: drop eligible lines where UnitPrice × Quantity ≤ 0 or Quantity ≤ 0 (free
 * items and zero-qty lines have nothing to discount).
 *
 * Step 2 — value math (Application_Level × Discount_Type):
 *   Per Line × Amount  → Discount_Value to each eligible line
 *   Per Line × Percent → UnitPrice × Quantity × pct/100 per eligible line
 *   Per Order × Amount  → targetValue = Discount_Value, distributed proportionately
 *   Per Order × Percent → targetValue = Σ line subtotal × pct/100, distributed proportionately
 *
 *   Proportionate distribution: lineAdjustment[i] = targetValue × (subtotal[i] / Σ subtotal),
 *   computed internally at 4 decimals, rounded to 2 for output. Residual cent (= targetValue −
 *   Σ rounded shares) is allocated to the largest-subtotal eligible line so the cart-level total
 *   matches targetValue exactly.
 *
 * Stacking when multiple codes hit the same line:
 *   - Adjustments are additive
 *   - Percent codes computed against original (UnitPrice × Quantity), NOT against progressively-
 *     discounted prices — so two 10% codes = 20% off, not 19%
 *   - Each line's CUMULATIVE adjustment across all codes is floored at the line's pre-discount
 *     subtotal — no negative NetPrice
 *
 * Override discount type is NOT supported in v1 (Discount_Type__c picklist is restricted to
 * "Percent" and "Amount"; see docs/promo-code/checkout-apply-flow.md and the Phase A6 handoff doc).
 *
 * The engine emits one CodeAllocation per (code, eligible OrderItem) pair where the capped
 * adjustment is > 0. CodeAllocation carries snapshots of Application_Level and Product_Scope_Type
 * (in addition to Discount_Type / Discount_Value) so the apply service can persist them onto
 * each PCI for audit.
 */
public with sharing class PromoCodeAllocationEngine {
  public class CodeAllocation {
    public Id promoCodeId;
    public String code;
    public Id orderItemId;
    public Decimal adjustmentAmount;
    public String discountTypeSnapshot;
    public Decimal discountValueSnapshot;
    public String applicationLevelSnapshot;
    public String productScopeTypeSnapshot;
  }

  public static List<CodeAllocation> allocate(
    List<Promo_Code__c> validCodes,
    List<OrderItem> orderItems
  ) {
    List<CodeAllocation> out = new List<CodeAllocation>();
    if (
      validCodes == null ||
      validCodes.isEmpty() ||
      orderItems == null ||
      orderItems.isEmpty()
    ) {
      return out;
    }

    // Pre-compute per-line subtotal once (UnitPrice × Quantity), kept at full precision for
    // proportional math and rounded only when emitting CodeAllocation amounts.
    Map<Id, Decimal> subtotalByLine = new Map<Id, Decimal>();
    // Per-line floor expressed as a line total: Floor_Price__c × Quantity. Null Floor_Price__c
    // is treated as 0 (no floor). The allocation cap keeps cumulative discount ≤ subtotal - floor
    // so the line's NetUnitPrice can never drop below Floor_Price__c regardless of stacking.
    Map<Id, Decimal> floorByLine = new Map<Id, Decimal>();
    for (OrderItem oi : orderItems) {
      Decimal unit = oi.UnitPrice == null ? 0 : oi.UnitPrice;
      Decimal qty = oi.Quantity == null ? 0 : oi.Quantity;
      subtotalByLine.put(
        oi.Id,
        (unit * qty).setScale(4, System.RoundingMode.HALF_UP)
      );
      Decimal floor = (Decimal) oi.get('Floor_Price__c');
      if (floor == null || floor < 0) {
        floor = 0;
      }
      floorByLine.put(
        oi.Id,
        (floor * qty).setScale(4, System.RoundingMode.HALF_UP)
      );
    }

    // Running cumulative adjustment per line — combined with floorByLine to clip stacking
    // so no line ever falls below its configured floor.
    Map<Id, Decimal> allocatedByLine = new Map<Id, Decimal>();
    for (Id oid : subtotalByLine.keySet())
      allocatedByLine.put(oid, 0);

    // Apply sequencing per design spec: Percent discounts apply before Amount discounts so a
    // dollar-off code can never claim headroom that a stacked % code would have taken first.
    // Within each discount-type bucket, the caller's input order is preserved (stable sort).
    List<Promo_Code__c> sortedCodes = sortByDiscountType(validCodes);

    for (Promo_Code__c code : sortedCodes) {
      List<OrderItem> eligible = filterEligible(code, orderItems);
      eligible = applyApplyGuards(eligible, subtotalByLine);
      if (eligible.isEmpty())
        continue;

      String level = code.Application_Level__c == null
        ? 'Per Order'
        : code.Application_Level__c;
      String dtype = code.Discount_Type__c;
      Decimal dval = code.Discount_Value__c == null
        ? 0
        : code.Discount_Value__c;
      if (dval <= 0)
        continue;

      if (level == 'Per Line') {
        allocatePerLine(
          code,
          dtype,
          dval,
          eligible,
          subtotalByLine,
          floorByLine,
          allocatedByLine,
          out
        );
      } else {
        allocatePerOrder(
          code,
          dtype,
          dval,
          eligible,
          subtotalByLine,
          floorByLine,
          allocatedByLine,
          out
        );
      }
    }

    return out;
  }

  /**
   * Stable sort: all Percent codes come before all Amount codes; within each bucket the caller's
   * input order is preserved. Unknown discount types (e.g., Override, currently dropped in v1)
   * sort to the end so they don't disturb the established sequencing.
   */
  private static List<Promo_Code__c> sortByDiscountType(
    List<Promo_Code__c> codes
  ) {
    List<Promo_Code__c> percentCodes = new List<Promo_Code__c>();
    List<Promo_Code__c> amountCodes = new List<Promo_Code__c>();
    List<Promo_Code__c> otherCodes = new List<Promo_Code__c>();
    for (Promo_Code__c c : codes) {
      String t = c.Discount_Type__c;
      if (t == 'Percent') {
        percentCodes.add(c);
      } else if (t == 'Amount') {
        amountCodes.add(c);
      } else {
        otherCodes.add(c);
      }
    }
    List<Promo_Code__c> out = new List<Promo_Code__c>();
    out.addAll(percentCodes);
    out.addAll(amountCodes);
    out.addAll(otherCodes);
    return out;
  }

  // ============================================================
  // Eligibility (Step 1)
  // ============================================================

  private static List<OrderItem> filterEligible(
    Promo_Code__c code,
    List<OrderItem> all
  ) {
    String scopeType = code.Product_Scope_Type__c == null
      ? 'All Items'
      : code.Product_Scope_Type__c;

    if (scopeType == 'All Items') {
      return new List<OrderItem>(all);
    }
    if (scopeType == 'Product Family') {
      Set<String> families = splitMultiPicklist(code.Product_Family_Scope__c);
      List<OrderItem> hits = new List<OrderItem>();
      for (OrderItem oi : all) {
        if (oi.Product2 == null || oi.Product2.Family == null)
          continue;
        if (families.contains(oi.Product2.Family.toLowerCase()))
          hits.add(oi);
      }
      return hits;
    }
    if (scopeType == 'Specific Membership Types') {
      Set<String> tokens = splitMultiPicklist(code.Member_Type_Scope__c);
      List<OrderItem> hits = new List<OrderItem>();
      for (OrderItem oi : all) {
        if (oi.Product2 == null || oi.Product2.Name == null)
          continue;
        String nameLc = oi.Product2.Name.toLowerCase();
        for (String t : tokens) {
          if (nameLc.contains(t)) {
            hits.add(oi);
            break;
          }
        }
      }
      return hits;
    }
    if (scopeType == 'Specific Products') {
      Set<String> codes = splitCsv(code.Specific_Products__c);
      List<OrderItem> hits = new List<OrderItem>();
      for (OrderItem oi : all) {
        if (oi.Product2 == null || oi.Product2.ProductCode == null)
          continue;
        if (codes.contains(oi.Product2.ProductCode.trim().toLowerCase()))
          hits.add(oi);
      }
      return hits;
    }
    return new List<OrderItem>();
  }

  /**
   * Drop eligible lines that have nothing to discount: zero/negative subtotal or zero qty.
   * Mirrors the design doc's "NetPrice ≤ 0 or Quantity ≤ 0" exclusion — at apply time NetPrice
   * isn't yet populated, so we guard against the pre-pricing equivalent (UnitPrice × Quantity).
   */
  private static List<OrderItem> applyApplyGuards(
    List<OrderItem> eligible,
    Map<Id, Decimal> subtotalByLine
  ) {
    List<OrderItem> out = new List<OrderItem>();
    for (OrderItem oi : eligible) {
      if (oi.Quantity == null || oi.Quantity <= 0)
        continue;
      Decimal subtotal = subtotalByLine.get(oi.Id);
      if (subtotal == null || subtotal <= 0)
        continue;
      out.add(oi);
    }
    return out;
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

  // ============================================================
  // Value math (Step 2)
  // ============================================================

  /**
   * Per Line: replicate full value to each eligible line. Adjustment is capped per-line by the
   * remaining headroom (subtotal − already-allocated by prior codes in this allocate() call).
   */
  private static void allocatePerLine(
    Promo_Code__c code,
    String discountType,
    Decimal discountValue,
    List<OrderItem> eligible,
    Map<Id, Decimal> subtotalByLine,
    Map<Id, Decimal> floorByLine,
    Map<Id, Decimal> allocatedByLine,
    List<CodeAllocation> out
  ) {
    for (OrderItem oi : eligible) {
      Decimal subtotal = subtotalByLine.get(oi.Id);
      Decimal raw;
      if (discountType == 'Percent') {
        raw = (subtotal *
          discountValue /
          100)
          .setScale(4, System.RoundingMode.HALF_UP);
      } else if (discountType == 'Amount') {
        raw = discountValue.setScale(4, System.RoundingMode.HALF_UP);
      } else {
        // Unsupported discount type (e.g., Override is dropped in v1).
        continue;
      }
      Decimal capped = capAdjustment(
        raw,
        subtotal,
        floorByLine.get(oi.Id),
        allocatedByLine.get(oi.Id)
      );
      if (capped > 0) {
        Decimal rounded = capped.setScale(2, System.RoundingMode.HALF_UP);
        if (rounded <= 0)
          continue;
        out.add(buildAllocation(code, oi.Id, rounded));
        allocatedByLine.put(oi.Id, allocatedByLine.get(oi.Id) + rounded);
      }
    }
  }

  /**
   * Per Order: compute a single targetValue (the total cart-level discount this code should
   * produce), then distribute proportionately across eligible lines by pre-discount subtotal.
   * Residual cent from rounding goes to the largest-subtotal line so the total exactly matches
   * targetValue. Each line's share is then capped at the line's remaining headroom.
   */
  private static void allocatePerOrder(
    Promo_Code__c code,
    String discountType,
    Decimal discountValue,
    List<OrderItem> eligible,
    Map<Id, Decimal> subtotalByLine,
    Map<Id, Decimal> floorByLine,
    Map<Id, Decimal> allocatedByLine,
    List<CodeAllocation> out
  ) {
    Decimal totalSubtotal = 0;
    for (OrderItem oi : eligible)
      totalSubtotal += subtotalByLine.get(oi.Id);
    if (totalSubtotal <= 0)
      return;

    Decimal targetValue;
    if (discountType == 'Percent') {
      targetValue = (totalSubtotal *
        discountValue /
        100)
        .setScale(4, System.RoundingMode.HALF_UP);
    } else if (discountType == 'Amount') {
      targetValue = discountValue.setScale(4, System.RoundingMode.HALF_UP);
    } else {
      return; // unsupported discount type (Override dropped in v1)
    }
    // targetValue can't exceed the eligible-subtotal pool — clamp here so the proportional
    // math doesn't try to over-allocate.
    if (targetValue > totalSubtotal)
      targetValue = totalSubtotal;

    // Compute per-line shares and identify the largest line for residual reconciliation.
    Map<Id, Decimal> shareByLine = new Map<Id, Decimal>();
    Decimal allocatedRunning = 0;
    Id largestLineId = null;
    Decimal largestSubtotal = -1;

    for (OrderItem oi : eligible) {
      Decimal subtotal = subtotalByLine.get(oi.Id);
      Decimal share = (targetValue *
        subtotal /
        totalSubtotal)
        .setScale(2, System.RoundingMode.HALF_UP);
      shareByLine.put(oi.Id, share);
      allocatedRunning += share;
      if (subtotal > largestSubtotal) {
        largestSubtotal = subtotal;
        largestLineId = oi.Id;
      }
    }

    // Reconcile rounding residual onto the largest-subtotal line.
    Decimal remainder =
      targetValue.setScale(2, System.RoundingMode.HALF_UP) - allocatedRunning;
    if (remainder != 0 && largestLineId != null) {
      shareByLine.put(
        largestLineId,
        shareByLine.get(largestLineId) + remainder
      );
    }

    // Emit, capped per-line by stacking headroom.
    for (OrderItem oi : eligible) {
      Decimal raw = shareByLine.get(oi.Id);
      Decimal capped = capAdjustment(
        raw,
        subtotalByLine.get(oi.Id),
        floorByLine.get(oi.Id),
        allocatedByLine.get(oi.Id)
      );
      if (capped > 0) {
        Decimal rounded = capped.setScale(2, System.RoundingMode.HALF_UP);
        if (rounded <= 0)
          continue;
        out.add(buildAllocation(code, oi.Id, rounded));
        allocatedByLine.put(oi.Id, allocatedByLine.get(oi.Id) + rounded);
      }
    }
  }

  /**
   * Caps a candidate adjustment so cumulative line-level discount never:
   *   - exceeds the line's pre-discount subtotal (NetLineTotal can't go negative), AND
   *   - exceeds (subtotal - floorLineTotal), where floorLineTotal = Floor_Price__c × Quantity
   *     (NetLineTotal can't drop below the configured per-line floor).
   * Null/0 floor degrades to the original "floor at zero" behavior.
   */
  private static Decimal capAdjustment(
    Decimal raw,
    Decimal subtotal,
    Decimal floorLineTotal,
    Decimal alreadyAllocated
  ) {
    if (raw <= 0)
      return 0;
    Decimal floor = floorLineTotal == null ? 0 : floorLineTotal;
    Decimal maxDiscountable = subtotal - floor;
    if (maxDiscountable <= 0)
      return 0;
    Decimal remainingHeadroom = maxDiscountable - alreadyAllocated;
    if (remainingHeadroom <= 0)
      return 0;
    return raw > remainingHeadroom ? remainingHeadroom : raw;
  }

  private static CodeAllocation buildAllocation(
    Promo_Code__c code,
    Id orderItemId,
    Decimal amount
  ) {
    CodeAllocation a = new CodeAllocation();
    a.promoCodeId = code.Id;
    a.code = code.Code__c;
    a.orderItemId = orderItemId;
    a.adjustmentAmount = amount;
    a.discountTypeSnapshot = code.Discount_Type__c;
    a.discountValueSnapshot = code.Discount_Value__c;
    a.applicationLevelSnapshot = code.Application_Level__c;
    a.productScopeTypeSnapshot = code.Product_Scope_Type__c;
    return a;
  }
}
