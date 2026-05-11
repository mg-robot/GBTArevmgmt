/**
 * Stateless validator for promo codes at apply time. Implements the 10 ordered validation rules
 * from docs/promo-code/checkout-apply-flow.md §4.4. Each call returns a structured CodeResult
 * with an explicit errorCode + member-facing errorMessage; the first failing check short-circuits.
 *
 * Rule order:
 *   1. NOT_FOUND               — Code+currency lookup returned no record.
 *   2. NOT_ACTIVE              — Status__c != 'Active'.
 *   3. OUT_OF_WINDOW           — NOW() outside Effective_Start_Date..Effective_End_Date.
 *   4. USAGE_EXCEEDED          — Total_Usage_Limit__c hit (Confirmed + Pending across all members).
 *   5. MEMBER_LIMIT_EXCEEDED   — Per_Member_Usage_Limit__c hit for the current Member.
 *   6. MEMBER_TYPE_INELIGIBLE  — No product in the cart is in Member_Type_Scope__c. The scope's
 *                                values mirror Membership product names — see field description.
 *   7. REGION_INELIGIBLE       — Cart's Order.Region__c not in Region_Scope__c.
 *   8. ACCOUNT_INELIGIBLE      — Order.AccountId != Promo_Code__c.Account__c.
 *   9. NOT_APPLICABLE_TO_CART  — No OrderItem matches Product_Scope_Type__c / Specific_Products__c.
 *  10. NOT_COMBINABLE          — Conflict with already-validated codes in this Apply set.
 *
 * Region is read from the Order's denormalized Region__c field (populated upstream by the join
 * flow). Member type is derived from the cart's products: Member_Type_Scope__c values mirror
 * Membership product names, so we check whether any line in the cart names a scope-listed product.
 * This avoids the validator needing to traverse Person Account fields and keeps it pure compute
 * given a cart context.
 *
 * Combinability rule (§4.4 note):
 *   If any code in the validated set has Combinable__c = false, no other code can join it.
 *   Otherwise, every code in the set must share the same Combination_Group__c.
 *
 * The class is stateless and 'with sharing'. Callers (PromoCodeApplyService) are responsible
 * for fetching parent records and usage counts before invoking validate().
 */
public with sharing class PromoCodeValidator {

    /**
     * Validate a single submitted code against a cart context.
     *
     * @param submittedCode   the raw string the member typed (used for error display when the
     *                        parent record is null / not found).
     * @param parent          the matching Promo_Code__c record (may be null → NOT_FOUND).
     * @param ctx             cart context: Order Id, AccountId, currency, region, member type,
     *                        OrderItems with Product2.Family/Name eager-loaded.
     * @param alreadyValid    parent records that have already passed validation in this Apply
     *                        event. Used by the combinability check.
     * @param usage           pre-aggregated Pending + Confirmed counts (global and per-member).
     * @return a fully-populated CodeResult; valid = true means the code passed all 10 checks.
     */
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
            return fail(cr, PromoCodeApplyService.ERR_NOT_FOUND,
                messageFor(PromoCodeApplyService.ERR_NOT_FOUND, null, ctx, cr.code));
        }
        cr.displayName = parent.Display_Name__c;

        // 2. NOT_ACTIVE
        if (parent.Status__c != 'Active') {
            return fail(cr, PromoCodeApplyService.ERR_NOT_ACTIVE,
                messageFor(PromoCodeApplyService.ERR_NOT_ACTIVE, parent, ctx, cr.code));
        }

        // 3. OUT_OF_WINDOW
        Datetime now = System.now();
        if (parent.Effective_Start_Date__c != null && now < parent.Effective_Start_Date__c) {
            return fail(cr, PromoCodeApplyService.ERR_OUT_OF_WINDOW,
                messageFor(PromoCodeApplyService.ERR_OUT_OF_WINDOW, parent, ctx, cr.code));
        }
        if (parent.Effective_End_Date__c != null && now > parent.Effective_End_Date__c) {
            return fail(cr, PromoCodeApplyService.ERR_OUT_OF_WINDOW,
                messageFor(PromoCodeApplyService.ERR_OUT_OF_WINDOW, parent, ctx, cr.code));
        }

        // 4. USAGE_EXCEEDED
        if (parent.Total_Usage_Limit__c != null) {
            Integer confirmedFromParent = parent.Confirmed_Usage_Count__c == null
                ? 0 : parent.Confirmed_Usage_Count__c.intValue();
            Integer totalUsed = usage.totalUsed(parent.Id, confirmedFromParent);
            if (totalUsed >= parent.Total_Usage_Limit__c.intValue()) {
                return fail(cr, PromoCodeApplyService.ERR_USAGE_EXCEEDED,
                    messageFor(PromoCodeApplyService.ERR_USAGE_EXCEEDED, parent, ctx, cr.code));
            }
        }

        // 5. MEMBER_LIMIT_EXCEEDED
        if (parent.Per_Member_Usage_Limit__c != null) {
            Integer memberUsed = usage.memberUsed(parent.Id);
            if (memberUsed >= parent.Per_Member_Usage_Limit__c.intValue()) {
                return fail(cr, PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED,
                    messageFor(PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED, parent, ctx, cr.code));
            }
        }

        // 6. MEMBER_TYPE_INELIGIBLE
        // Member_Type_Scope__c values mirror Membership Product names (per the field's design-doc
        // description). The check is: at least one product in the cart must match the scope list.
        if (!String.isBlank(parent.Member_Type_Scope__c)) {
            if (!anyCartProductInScope(parent.Member_Type_Scope__c, ctx.orderItems)) {
                return fail(cr, PromoCodeApplyService.ERR_MEMBER_TYPE_INELIGIBLE,
                    messageFor(PromoCodeApplyService.ERR_MEMBER_TYPE_INELIGIBLE, parent, ctx, cr.code));
            }
        }

        // 7. REGION_INELIGIBLE
        if (!String.isBlank(parent.Region_Scope__c)) {
            if (!multiPicklistContains(parent.Region_Scope__c, ctx.region)) {
                return fail(cr, PromoCodeApplyService.ERR_REGION_INELIGIBLE,
                    messageFor(PromoCodeApplyService.ERR_REGION_INELIGIBLE, parent, ctx, cr.code));
            }
        }

        // 8. ACCOUNT_INELIGIBLE
        if (parent.Account__c != null && parent.Account__c != ctx.accountId) {
            return fail(cr, PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE,
                messageFor(PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE, parent, ctx, cr.code));
        }

        // 9. NOT_APPLICABLE_TO_CART
        if (!hasQualifyingLine(parent, ctx.orderItems)) {
            return fail(cr, PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
                messageFor(PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART, parent, ctx, cr.code));
        }

        // 10. NOT_COMBINABLE
        if (!isCombinableWith(parent, alreadyValid)) {
            return fail(cr, PromoCodeApplyService.ERR_NOT_COMBINABLE,
                messageFor(PromoCodeApplyService.ERR_NOT_COMBINABLE, parent, ctx, cr.code));
        }

        cr.valid = true;
        return cr;
    }

    /**
     * Aggregate Pending + Confirmed PCI counts across a set of parent codes, in two SOQLs.
     * Used by validation rules 4 (USAGE_EXCEEDED) and 5 (MEMBER_LIMIT_EXCEEDED).
     *
     * @param promoCodeIds  parent codes to count usage for.
     * @param memberId      the member (Person Account) whose per-member usage we also tally.
     */
    public static PromoCodeApplyService.UsageCounts fetchUsageCounts(Set<Id> promoCodeIds, Id memberId) {
        PromoCodeApplyService.UsageCounts uc = new PromoCodeApplyService.UsageCounts();
        if (promoCodeIds == null || promoCodeIds.isEmpty()) {
            return uc;
        }

        for (AggregateResult ar : [
            SELECT Promo_Code__c parentId, Status__c status, COUNT(Id) cnt
            FROM Promo_Code_Item__c
            WHERE Promo_Code__c IN :promoCodeIds
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
                WHERE Promo_Code__c IN :promoCodeIds
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

    /**
     * Two-arg overload used by PromoCodeApplyService to look up a member-facing message after
     * the validator has already returned a result (e.g., downgraded-NOT_APPLICABLE_TO_CART case).
     */
    public static String messageFor(String errorCode, Promo_Code__c parent, PromoCodeApplyService.OrderContext ctx) {
        return messageFor(errorCode, parent, ctx, parent == null ? '' : parent.Code__c);
    }

    public static String messageFor(
        String errorCode,
        Promo_Code__c parent,
        PromoCodeApplyService.OrderContext ctx,
        String submittedCode
    ) {
        if (errorCode == PromoCodeApplyService.ERR_NOT_FOUND) {
            String iso = ctx == null || ctx.currencyIsoCode == null ? '' : ctx.currencyIsoCode;
            return String.isBlank(iso)
                ? 'Code "' + submittedCode + '" was not found.'
                : 'Code "' + submittedCode + '" was not found for currency ' + iso + '.';
        }
        if (errorCode == PromoCodeApplyService.ERR_NOT_ACTIVE) {
            return 'This code is not currently active.';
        }
        if (errorCode == PromoCodeApplyService.ERR_OUT_OF_WINDOW) {
            return 'This code is not valid right now' + effectiveWindowSuffix(parent) + '.';
        }
        if (errorCode == PromoCodeApplyService.ERR_USAGE_EXCEEDED) {
            return 'This code has reached its usage limit.';
        }
        if (errorCode == PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED) {
            return 'You\'ve already used this code the maximum number of times.';
        }
        if (errorCode == PromoCodeApplyService.ERR_MEMBER_TYPE_INELIGIBLE) {
            return 'This code is not available for your member type.';
        }
        if (errorCode == PromoCodeApplyService.ERR_REGION_INELIGIBLE) {
            return 'This code is not available in your region.';
        }
        if (errorCode == PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE) {
            return 'This code is restricted to a specific account.';
        }
        if (errorCode == PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART) {
            return 'This code doesn\'t apply to any items in your cart.';
        }
        if (errorCode == PromoCodeApplyService.ERR_NOT_COMBINABLE) {
            return 'This code can\'t be combined with the codes already applied. Remove the others to apply this one.';
        }
        return 'This code could not be applied.';
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

    private static Boolean multiPicklistContains(String fieldValue, String target) {
        if (String.isBlank(fieldValue) || String.isBlank(target)) return false;
        for (String v : fieldValue.split(';')) {
            if (v.trim().equalsIgnoreCase(target.trim())) return true;
        }
        return false;
    }

    private static Boolean anyCartProductInScope(String multiPicklistValue, List<OrderItem> orderItems) {
        if (orderItems == null || orderItems.isEmpty()) return false;
        Set<String> scopeNames = new Set<String>();
        for (String v : multiPicklistValue.split(';')) {
            String trimmed = v.trim();
            if (!String.isBlank(trimmed)) scopeNames.add(trimmed.toLowerCase());
        }
        for (OrderItem oi : orderItems) {
            if (oi.Product2 != null && oi.Product2.Name != null
                && scopeNames.contains(oi.Product2.Name.toLowerCase())) {
                return true;
            }
        }
        return false;
    }

    private static Boolean hasQualifyingLine(Promo_Code__c code, List<OrderItem> orderItems) {
        if (orderItems == null || orderItems.isEmpty()) return false;
        String scopeType = code.Product_Scope_Type__c;
        if (scopeType == null || scopeType == 'All Items') return true;

        String spec = code.Specific_Products__c;
        if (scopeType == 'Product Family') {
            if (String.isBlank(spec)) return false;
            String family = spec.trim();
            for (OrderItem oi : orderItems) {
                if (oi.Product2 != null && oi.Product2.Family == family) return true;
            }
            return false;
        }
        if (scopeType == 'Specific Products') {
            if (String.isBlank(spec)) return false;
            Set<String> names = new Set<String>();
            for (String token : spec.split(',')) {
                String trimmed = token.trim();
                if (!String.isBlank(trimmed)) names.add(trimmed);
            }
            for (OrderItem oi : orderItems) {
                if (oi.Product2 != null && names.contains(oi.Product2.Name)) return true;
            }
            return false;
        }
        return false;
    }

    private static Boolean isCombinableWith(Promo_Code__c candidate, List<Promo_Code__c> alreadyValid) {
        if (alreadyValid == null || alreadyValid.isEmpty()) return true;

        // If candidate itself is non-combinable, it can't join an existing set.
        if (candidate.Combinable__c == false) return false;

        // If any existing code is non-combinable, candidate can't join.
        for (Promo_Code__c existing : alreadyValid) {
            if (existing.Combinable__c == false) return false;
        }

        // All codes in the set must share the same Combination_Group__c.
        String candidateGroup = candidate.Combination_Group__c;
        if (String.isBlank(candidateGroup)) {
            // Combinable=true with no group — treat as not-combinable with anything (defensive;
            // VR_PromoCode_RequireCombinationGroup should prevent this state at the data layer).
            return false;
        }
        for (Promo_Code__c existing : alreadyValid) {
            String existingGroup = existing.Combination_Group__c;
            if (existingGroup == null || !existingGroup.equalsIgnoreCase(candidateGroup)) {
                return false;
            }
        }
        return true;
    }

    private static String effectiveWindowSuffix(Promo_Code__c parent) {
        if (parent == null) return '';
        if (parent.Effective_Start_Date__c == null && parent.Effective_End_Date__c == null) return '';
        String startDisplay = parent.Effective_Start_Date__c == null
            ? 'any time' : parent.Effective_Start_Date__c.format();
        String endDisplay = parent.Effective_End_Date__c == null
            ? 'no end' : parent.Effective_End_Date__c.format();
        return ' (effective ' + startDisplay + ' – ' + endDisplay + ')';
    }
}
