/**
 * ARM Procedure Plan pre-hook that writes the aggregated promo discount amount onto each
 * OrderItem in the pricing context. Invoked by the Procedure Plan's Apex section before the
 * GBTA Revenue Pricing Procedure runs; the pricing procedure's Formula element then subtracts
 * the value from NetPrice.
 *
 * Implements `RevSignaling.SignalingApexProcessor` (ARM Procedure Plan Apex hook interface,
 * introduced Summer '25, stable Spring '26+). See docs/promo-code/checkout-apply-flow.md §6.3
 * for the design rationale and §6.4 for the Procedure Plan setup steps.
 *
 * Mental model: this hook does NOT touch OrderItem SObject records directly. It reads and
 * writes against the in-memory pricing context tree via `Context.IndustriesContext`. The
 * pricing engine persists the values back to OrderItem as part of its normal pipeline.
 *
 * Reset + re-apply pattern: the hook writes Promotion_Value__c for EVERY OrderItem in context,
 * not just those with current Pending PCIs. OrderItems without PCIs get a value of 0 — this
 * clears any stale promo state so removed codes don't ghost-apply on subsequent re-prices.
 *
 * Required Revenue Settings (one-time org config — see §6.3):
 *   - "Procedure Plan Orchestration for Pricing"
 *   - "Exclude Default and Sales Transaction Type Pricing Procedures"
 *
 * Testability note: the platform classes RevSignaling.TransactionRequest /
 * Context.IndustriesContext aren't constructable in test context, so the pure-compute helpers
 * (aggregateAdjustments + buildNodeUpdates) are extracted and @TestVisible. End-to-end coverage
 * happens in the sandbox via the "Promo Code Entry — Dev Test" Lightning App Page once the
 * Procedure Plan is wired.
 */
global with sharing class PromoCodePricingPreHook implements RevSignaling.SignalingApexProcessor {

    global RevSignaling.TransactionResponse execute(RevSignaling.TransactionRequest request) {
        RevSignaling.TransactionResponse response = new RevSignaling.TransactionResponse();
        String contextId = request == null ? null : request.ctxInstanceId;

        if (String.isBlank(contextId)) {
            response.status = RevSignaling.TransactionStatus.FAILED;
            response.message = 'PromoCodePricingPreHook: missing context instance Id.';
            return response;
        }

        Context.IndustriesContext industriesContext = new Context.IndustriesContext();

        try {
            // 1. Query SalesTransactionItem nodes from the in-memory pricing context.
            Map<String, Object> queryInput = new Map<String, Object>{
                'contextId' => contextId,
                'tags' => new List<String>{ 'SalesTransactionItem' }
            };
            Map<String, Object> queryResult = (Map<String, Object>)
                industriesContext.queryTags(queryInput).get('queryResult');
            List<Object> itemDataList = queryResult == null
                ? null
                : (List<Object>) queryResult.get('SalesTransactionItem');

            Map<Id, List<Object>> orderItemToDataPath = extractOrderItemPaths(itemDataList);
            Set<Id> orderItemIds = orderItemToDataPath.keySet();

            if (orderItemIds.isEmpty()) {
                response.status = RevSignaling.TransactionStatus.SUCCESS;
                response.message = 'PromoCodePricingPreHook: no OrderItems in pricing context.';
                return response;
            }

            Map<Id, Decimal> adjustmentByOrderItem = aggregateAdjustments(orderItemIds);
            List<Map<String, Object>> nodeUpdates =
                buildNodeUpdates(orderItemIds, orderItemToDataPath, adjustmentByOrderItem);

            if (!nodeUpdates.isEmpty()) {
                industriesContext.updateContextAttributes(new Map<String, Object>{
                    'contextId' => contextId,
                    'nodePathAndAttributes' => nodeUpdates
                });
            }

            Integer applied = adjustmentByOrderItem.size();
            Integer reset = nodeUpdates.size() - applied;
            response.status = RevSignaling.TransactionStatus.SUCCESS;
            response.message = 'PromoCodePricingPreHook: ' + applied + ' adjustment(s) applied, '
                + reset + ' OrderItem(s) reset.';

        } catch (Exception e) {
            response.status = RevSignaling.TransactionStatus.FAILED;
            response.message = 'PromoCodePricingPreHook error: ' + e.getMessage();
        }
        return response;
    }

    // -----------------------------------------------------------------------
    // Extracted helpers — pure compute, no platform-class dependencies, @TestVisible
    // -----------------------------------------------------------------------

    /**
     * Walks the queried SalesTransactionItem nodes and returns a map of OrderItem Id → its
     * dataPath in the context tree. Skips nodes without a LineItem tag or a null OrderItem Id.
     */
    @TestVisible
    private static Map<Id, List<Object>> extractOrderItemPaths(List<Object> itemDataList) {
        Map<Id, List<Object>> result = new Map<Id, List<Object>>();
        if (itemDataList == null) return result;
        for (Object itemObj : itemDataList) {
            Map<String, Object> itemNode = (Map<String, Object>) itemObj;
            Map<String, Object> tags = (Map<String, Object>) itemNode.get('tagValue');
            if (tags == null || !tags.containsKey('LineItem')) continue;
            Object lineItemEntry = tags.get('LineItem');
            if (!(lineItemEntry instanceof Map<String, Object>)) continue;
            Object oiIdObj = ((Map<String, Object>) lineItemEntry).get('tagValue');
            if (oiIdObj == null) continue;
            Id orderItemId = (Id) oiIdObj;
            result.put(orderItemId, (List<Object>) itemNode.get('dataPath'));
        }
        return result;
    }

    /**
     * Sums Applied_Discount_Amount__c per OrderItem for all Pending Promo_Code_Item__c records
     * tied to the given OrderItem Ids. OrderItems with no Pending PCIs are absent from the
     * returned map (callers MUST treat absence as 0 for the reset behavior).
     */
    @TestVisible
    private static Map<Id, Decimal> aggregateAdjustments(Set<Id> orderItemIds) {
        Map<Id, Decimal> result = new Map<Id, Decimal>();
        if (orderItemIds == null || orderItemIds.isEmpty()) return result;
        for (Promo_Code_Item__c pci : [
            SELECT Order_Item__c, Applied_Discount_Amount__c
            FROM Promo_Code_Item__c
            WHERE Order_Item__c IN :orderItemIds
              AND Status__c = 'Pending'
        ]) {
            Decimal current = result.get(pci.Order_Item__c);
            Decimal amount = pci.Applied_Discount_Amount__c == null
                ? 0
                : pci.Applied_Discount_Amount__c;
            result.put(pci.Order_Item__c, (current == null ? 0 : current) + amount);
        }
        return result;
    }

    /**
     * Builds the node-update payloads for `updateContextAttributes`. One entry per OrderItem in
     * orderItemIds — OrderItems without an entry in adjustmentByOrderItem get value=0, which is
     * the reset behavior that prevents ghost-applies of removed promo codes.
     */
    @TestVisible
    private static List<Map<String, Object>> buildNodeUpdates(
        Set<Id> orderItemIds,
        Map<Id, List<Object>> orderItemToDataPath,
        Map<Id, Decimal> adjustmentByOrderItem
    ) {
        List<Map<String, Object>> nodeUpdates = new List<Map<String, Object>>();
        if (orderItemIds == null) return nodeUpdates;
        for (Id oiId : orderItemIds) {
            List<Object> fullPath = orderItemToDataPath == null
                ? null
                : orderItemToDataPath.get(oiId);
            if (fullPath == null || fullPath.size() < 3) continue;
            List<Object> nodePath = new List<Object>{ fullPath.get(1), fullPath.get(2) };

            Decimal adjustment = adjustmentByOrderItem != null
                    && adjustmentByOrderItem.containsKey(oiId)
                ? adjustmentByOrderItem.get(oiId)
                : 0;

            nodeUpdates.add(new Map<String, Object>{
                'nodePath' => new Map<String, Object>{ 'dataPath' => nodePath },
                'attributes' => new List<Object>{
                    new Map<String, Object>{
                        'attributeName' => 'Promotion_Value__c',
                        'attributeValue' => String.valueOf(adjustment)
                    }
                }
            });
        }
        return nodeUpdates;
    }
}
