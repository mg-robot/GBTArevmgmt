/**
 * Computes per-line discount allocations for a set of validated promo codes against a cart of
 * OrderItems. Pure compute — no DML, no SOQL. Inputs are already-fetched records; outputs are
 * in-memory CodeAllocation instances that the apply service persists as Promo_Code_Item__c.
 *
 * Allocation rules — see docs/promo-code/checkout-apply-flow.md §5:
 * - Qualifying lines per code are filtered by Product_Scope_Type__c:
 *     "All Items"         → every OrderItem
 *     "Product Family"    → OrderItems whose Product2.Family matches the (single) value in
 *                           Specific_Products__c
 *     "Specific Products" → OrderItems whose Product2.Name is in the CSV of Specific_Products__c
 * - Percent codes: each qualifying line is reduced by (UnitPrice × Quantity × value/100).
 * - Amount codes with multiple qualifying lines: the fixed amount is distributed pro-rata across
 *   lines by each line's pre-discount subtotal (UnitPrice × Quantity). Avoids the
 *   "full amount on every line" multiplication while staying intuitive. See §5.3.
 * - Stacking (§5.4): when multiple codes apply to the same line, the per-code adjustments are
 *   summed (additive). Percent codes are computed against the original UnitPrice, not against a
 *   progressively-discounted price, so two 10% codes = 20% off, not 19%.
 * - Each line's total adjustment is floored at its pre-discount subtotal so NetPrice never goes
 *   below zero.
 *
 * The engine emits one CodeAllocation per (code, OrderItem) pair where the adjustment is > 0.
 * Lines that qualify but receive a zero adjustment (e.g., a percent code with value=0) are
 * skipped — there's nothing to record.
 */
public with sharing class PromoCodeAllocationEngine {

    public class CodeAllocation {
        public Id promoCodeId;
        public String code;
        public Id orderItemId;
        public Decimal adjustmentAmount;
        public String discountTypeSnapshot;
        public Decimal discountValueSnapshot;
    }

    /**
     * Allocate validated promo codes across the OrderItems in the cart.
     *
     * @param validCodes     parent Promo_Code__c records that have passed all 10 validation
     *                       checks. Caller is responsible for prior validation.
     * @param orderItems     OrderItems in the cart, eager-loaded with Product2.Family +
     *                       Product2.Name + UnitPrice + Quantity.
     * @return list of CodeAllocation, one per (code, qualifying OrderItem) pair with a non-zero
     *         adjustment. List is grouped by code (caller-friendly for DML construction) but
     *         the order within a code is not guaranteed.
     */
    public static List<CodeAllocation> allocate(
        List<Promo_Code__c> validCodes,
        List<OrderItem> orderItems
    ) {
        List<CodeAllocation> out = new List<CodeAllocation>();
        if (validCodes == null || validCodes.isEmpty() || orderItems == null || orderItems.isEmpty()) {
            return out;
        }

        // Pre-compute per-line subtotal once (UnitPrice × Quantity). Floor for the stacking cap.
        Map<Id, Decimal> subtotalByLine = new Map<Id, Decimal>();
        for (OrderItem oi : orderItems) {
            Decimal unit = oi.UnitPrice == null ? 0 : oi.UnitPrice;
            Decimal qty = oi.Quantity == null ? 0 : oi.Quantity;
            subtotalByLine.put(oi.Id, (unit * qty).setScale(2, System.RoundingMode.HALF_UP));
        }

        // Running tally of allocations already assigned to each line, used to floor stacking.
        Map<Id, Decimal> allocatedByLine = new Map<Id, Decimal>();
        for (Id oid : subtotalByLine.keySet()) allocatedByLine.put(oid, 0);

        for (Promo_Code__c code : validCodes) {
            List<OrderItem> qualifying = filterQualifying(code, orderItems);
            if (qualifying.isEmpty()) {
                continue;
            }

            String discountType = code.Discount_Type__c;
            Decimal discountValue = code.Discount_Value__c == null ? 0 : code.Discount_Value__c;

            if (discountType == 'Percent') {
                allocatePercent(code, qualifying, subtotalByLine, allocatedByLine, out);
            } else if (discountType == 'Amount') {
                allocateAmount(code, qualifying, subtotalByLine, allocatedByLine, out);
            }
        }

        return out;
    }

    private static List<OrderItem> filterQualifying(Promo_Code__c code, List<OrderItem> all) {
        String scopeType = code.Product_Scope_Type__c;
        String spec = code.Specific_Products__c;

        if (scopeType == null || scopeType == 'All Items') {
            return all;
        }
        if (scopeType == 'Product Family') {
            String family = spec == null ? null : spec.trim();
            List<OrderItem> hits = new List<OrderItem>();
            for (OrderItem oi : all) {
                if (oi.Product2 != null && oi.Product2.Family == family) {
                    hits.add(oi);
                }
            }
            return hits;
        }
        if (scopeType == 'Specific Products') {
            Set<String> names = new Set<String>();
            if (spec != null) {
                for (String token : spec.split(',')) {
                    String trimmed = token.trim();
                    if (!String.isBlank(trimmed)) names.add(trimmed);
                }
            }
            List<OrderItem> hits = new List<OrderItem>();
            for (OrderItem oi : all) {
                if (oi.Product2 != null && names.contains(oi.Product2.Name)) {
                    hits.add(oi);
                }
            }
            return hits;
        }
        return new List<OrderItem>();
    }

    private static void allocatePercent(
        Promo_Code__c code,
        List<OrderItem> qualifying,
        Map<Id, Decimal> subtotalByLine,
        Map<Id, Decimal> allocatedByLine,
        List<CodeAllocation> out
    ) {
        Decimal pct = code.Discount_Value__c == null ? 0 : code.Discount_Value__c;
        if (pct <= 0) return;

        for (OrderItem oi : qualifying) {
            Decimal subtotal = subtotalByLine.get(oi.Id);
            Decimal raw = (subtotal * pct / 100).setScale(2, System.RoundingMode.HALF_UP);
            Decimal capped = capAdjustment(raw, subtotal, allocatedByLine.get(oi.Id));
            if (capped > 0) {
                out.add(buildAllocation(code, oi.Id, capped));
                allocatedByLine.put(oi.Id, allocatedByLine.get(oi.Id) + capped);
            }
        }
    }

    private static void allocateAmount(
        Promo_Code__c code,
        List<OrderItem> qualifying,
        Map<Id, Decimal> subtotalByLine,
        Map<Id, Decimal> allocatedByLine,
        List<CodeAllocation> out
    ) {
        Decimal amt = code.Discount_Value__c == null ? 0 : code.Discount_Value__c;
        if (amt <= 0) return;

        // Pro-rata distribution by pre-discount subtotal.
        Decimal totalSubtotal = 0;
        for (OrderItem oi : qualifying) {
            totalSubtotal += subtotalByLine.get(oi.Id);
        }
        if (totalSubtotal <= 0) return;

        // Compute shares, then reconcile rounding remainder onto the largest-subtotal line so the
        // sum of allocations exactly equals the intended amount (modulo per-line caps).
        Map<Id, Decimal> shareByLine = new Map<Id, Decimal>();
        Decimal allocatedRunning = 0;
        Id largestLineId = null;
        Decimal largestSubtotal = -1;

        for (OrderItem oi : qualifying) {
            Decimal subtotal = subtotalByLine.get(oi.Id);
            Decimal share = (amt * subtotal / totalSubtotal).setScale(2, System.RoundingMode.HALF_UP);
            shareByLine.put(oi.Id, share);
            allocatedRunning += share;
            if (subtotal > largestSubtotal) {
                largestSubtotal = subtotal;
                largestLineId = oi.Id;
            }
        }

        Decimal remainder = amt - allocatedRunning;
        if (remainder != 0 && largestLineId != null) {
            shareByLine.put(largestLineId, shareByLine.get(largestLineId) + remainder);
        }

        for (OrderItem oi : qualifying) {
            Decimal raw = shareByLine.get(oi.Id);
            Decimal capped = capAdjustment(raw, subtotalByLine.get(oi.Id), allocatedByLine.get(oi.Id));
            if (capped > 0) {
                out.add(buildAllocation(code, oi.Id, capped));
                allocatedByLine.put(oi.Id, allocatedByLine.get(oi.Id) + capped);
            }
        }
    }

    private static Decimal capAdjustment(Decimal raw, Decimal subtotal, Decimal alreadyAllocated) {
        if (raw <= 0) return 0;
        Decimal remainingHeadroom = subtotal - alreadyAllocated;
        if (remainingHeadroom <= 0) return 0;
        return raw > remainingHeadroom ? remainingHeadroom : raw;
    }

    private static CodeAllocation buildAllocation(Promo_Code__c code, Id orderItemId, Decimal amount) {
        CodeAllocation a = new CodeAllocation();
        a.promoCodeId = code.Id;
        a.code = code.Code__c;
        a.orderItemId = orderItemId;
        a.adjustmentAmount = amount;
        a.discountTypeSnapshot = code.Discount_Type__c;
        a.discountValueSnapshot = code.Discount_Value__c;
        return a;
    }
}
