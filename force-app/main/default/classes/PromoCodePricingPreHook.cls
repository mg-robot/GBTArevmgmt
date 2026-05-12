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
  global RevSignaling.TransactionResponse execute(
    RevSignaling.TransactionRequest request
  ) {
    System.debug('Statrting prehook here');
    String contextId = request == null ? null : request.ctxInstanceId;
    if (String.isBlank(contextId)) {
      return buildResponse(
        RevSignaling.TransactionStatus.FAILED,
        'PromoCodePricingPreHook: missing context instance Id.'
      );
    }
    System.debug(contextId);

    Context.IndustriesContext industriesContext = new Context.IndustriesContext();
    try {
      List<Object> itemDataList = queryTransactionItems(
        industriesContext,
        contextId
      );
      System.debug(itemDataList);
      Map<String, List<Object>> orderItemToDataPath = extractOrderItemPaths(
        itemDataList
      );
      System.debug('past extractOderItems Paths');
      System.debug(orderItemToDataPath);
      Set<String> orderItemIds = orderItemToDataPath.keySet();
      System.debug(orderItemIds);

      if (orderItemIds.isEmpty()) {
        return buildResponse(
          RevSignaling.TransactionStatus.SUCCESS,
          'PromoCodePricingPreHook: no OrderItems in pricing context.'
        );
      }

      Map<String, Decimal> adjustmentByOrderItem = aggregateAdjustments(
        orderItemIds
      );
      System.debug(adjustmentByOrderItem);
      List<Map<String, Object>> nodeUpdates = buildNodeUpdates(
        orderItemIds,
        orderItemToDataPath,
        adjustmentByOrderItem
      );
      System.debug(nodeUpdates);
      submitContextUpdates(industriesContext, contextId, nodeUpdates);

      return buildResponse(
        RevSignaling.TransactionStatus.SUCCESS,
        summarizeResult(adjustmentByOrderItem.size(), nodeUpdates.size())
      );
    } catch (Exception e) {
      return buildResponse(
        RevSignaling.TransactionStatus.FAILED,
        'PromoCodePricingPreHook error: ' + e.getMessage()
      );
    }
  }

  private static List<Object> queryTransactionItems(
    Context.IndustriesContext industriesContext,
    String contextId
  ) {
    Map<String, Object> queryResult = (Map<String, Object>) industriesContext.queryTags(
        new Map<String, Object>{
          'contextId' => contextId,
          'tags' => new List<String>{ 'SalesTransactionItem' }
        }
      )
      .get('queryResult');
    return queryResult == null
      ? null
      : (List<Object>) queryResult.get('SalesTransactionItem');
  }

  @TestVisible
  private static void submitContextUpdates(
    Context.IndustriesContext industriesContext,
    String contextId,
    List<Map<String, Object>> nodeUpdates
  ) {
    if (nodeUpdates == null || nodeUpdates.isEmpty())
      return;
    industriesContext.updateContextAttributes(
      new Map<String, Object>{
        'contextId' => contextId,
        'nodePathAndAttributes' => nodeUpdates
      }
    );
  }

  @TestVisible
  private static String summarizeResult(
    Integer adjustmentCount,
    Integer totalUpdates
  ) {
    Integer applied = adjustmentCount == null ? 0 : adjustmentCount;
    Integer reset = (totalUpdates == null ? 0 : totalUpdates) - applied;
    return 'PromoCodePricingPreHook: ' +
      applied +
      ' adjustment(s) applied, ' +
      reset +
      ' OrderItem(s) reset.';
  }

  @TestVisible
  private static RevSignaling.TransactionResponse buildResponse(
    RevSignaling.TransactionStatus status,
    String message
  ) {
    RevSignaling.TransactionResponse response = new RevSignaling.TransactionResponse();
    response.status = status;
    response.message = message;
    return response;
  }

  // -----------------------------------------------------------------------
  // Extracted helpers — pure compute, no platform-class dependencies, @TestVisible
  // -----------------------------------------------------------------------

  /**
   * Walks the queried SalesTransactionItem nodes and returns a map of OrderItem Id → its
   * dataPath in the context tree. Skips nodes without a LineItem tag, a null OrderItem Id, or
   * a LineItem dmlStatus of 'DELETED' (lines removed during the same pricing pass still appear
   * in queryTags output but should not receive context updates).
   */
  @TestVisible
  private static Map<String, List<Object>> extractOrderItemPaths(
    List<Object> itemDataList
  ) {
    Map<String, List<Object>> result = new Map<String, List<Object>>();
    if (itemDataList == null)
      return result;
    for (Object itemObj : itemDataList) {
      Map<String, Object> itemNode = (Map<String, Object>) itemObj;
      System.debug('itemNode: ' + itemNode);
      Map<String, Object> tags = (Map<String, Object>) itemNode.get('tagValue');
      System.debug('tags: ' + tags);
      if (tags == null || !tags.containsKey('LineItem'))
        continue;
      Object lineItemEntry = tags.get('LineItem');
      System.debug('LineItem: ' + lineItemEntry);
      if (!(lineItemEntry instanceof Map<String, Object>))
        continue;
      Map<String, Object> lineItemTag = (Map<String, Object>) lineItemEntry;
      System.debug('lineItemTag: ' + lineItemTag);
      Object dmlStatus = lineItemTag.get('dmlStatus');
      if (
        dmlStatus != null &&
        String.valueOf(dmlStatus).equalsIgnoreCase('DELETED')
      )
        continue;
      Object oiIdObj = lineItemTag.get('tagValue');
      if (oiIdObj == null)
        continue;
      System.debug('oiIdObj: ' + oiIdObj);
      String orderItemId = String.valueOf(oiIdObj);
      System.debug('orderItemId: ' + orderItemId);
      result.put(orderItemId, (List<Object>) itemNode.get('dataPath'));
      System.debug(result);
    }
    return result;
  }

  /**
   * Sums Applied_Discount_Amount__c per OrderItem for all Pending Promo_Code_Item__c records
   * tied to the given OrderItem Ids. OrderItems with no Pending PCIs are absent from the
   * returned map (callers MUST treat absence as 0 for the reset behavior).
   */
  @TestVisible
  private static Map<String, Decimal> aggregateAdjustments(
    Set<String> orderItemIds
  ) {
    Map<String, Decimal> result = new Map<String, Decimal>();
    if (orderItemIds == null || orderItemIds.isEmpty())
      return result;
    for (Promo_Code_Item__c pci : [
      SELECT Order_Item__c, Applied_Discount_Amount__c
      FROM Promo_Code_Item__c
      WHERE Order_Item__c IN :orderItemIds AND Status__c = 'Pending'
    ]) {
      String oiKey = String.valueOf(pci.Order_Item__c);
      Decimal current = result.get(oiKey);
      Decimal amount = pci.Applied_Discount_Amount__c == null
        ? 0
        : pci.Applied_Discount_Amount__c;
      result.put(oiKey, (current == null ? 0 : current) + amount);
    }
    return result;
  }

  /**
   * Builds the node-update payloads for `updateContextAttributes`. One entry per OrderItem in
   * orderItemIds — OrderItems without an entry in adjustmentByOrderItem get value=0, which is
   * the reset behavior that prevents ghost-applies of removed promo codes.
   *
   * nodePath construction follows the canonical Salesforce pattern: strip the leading contextId
   * (index 0) from the queried dataPath and pass the remainder. This is robust to nested or
   * extended paths (e.g., bundles) rather than hardcoding specific indices.
   *
   * attributeValue is passed as Decimal (not stringified) so the pricing engine doesn't
   * re-parse on the receiving side.
   */
  @TestVisible
  private static List<Map<String, Object>> buildNodeUpdates(
    Set<String> orderItemIds,
    Map<String, List<Object>> orderItemToDataPath,
    Map<String, Decimal> adjustmentByOrderItem
  ) {
    List<Map<String, Object>> nodeUpdates = new List<Map<String, Object>>();
    if (orderItemIds == null)
      return nodeUpdates;
    for (String oiId : orderItemIds) {
      List<Object> fullPath = orderItemToDataPath == null
        ? null
        : orderItemToDataPath.get(oiId);
      if (fullPath == null || fullPath.size() < 2)
        continue;
      // Copy then strip the leading contextId — don't mutate the caller's list.
      List<Object> nodePath = new List<Object>(fullPath);
      nodePath.remove(0);

      Decimal adjustment = adjustmentByOrderItem != null &&
        adjustmentByOrderItem.containsKey(oiId)
        ? adjustmentByOrderItem.get(oiId)
        : 0;

      nodeUpdates.add(
        new Map<String, Object>{
          'nodePath' => new Map<String, Object>{ 'dataPath' => nodePath },
          'attributes' => new List<Object>{
            new Map<String, Object>{
              'attributeName' => 'Promotion_Value__c',
              'attributeValue' => adjustment
            }
          }
        }
      );
    }
    return nodeUpdates;
  }
}
