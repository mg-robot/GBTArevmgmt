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
    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodePricingPreHook: execute() entered ==='
    );
    String contextId = request == null ? null : request.ctxInstanceId;
    System.debug(LoggingLevel.INFO, 'ctxInstanceId=' + contextId);
    if (String.isBlank(contextId)) {
      System.debug(
        LoggingLevel.WARN,
        'PromoCodePricingPreHook: missing context instance Id — returning FAILED.'
      );
      return buildResponse(
        RevSignaling.TransactionStatus.FAILED,
        'PromoCodePricingPreHook: missing context instance Id.'
      );
    }

    Context.IndustriesContext industriesContext = new Context.IndustriesContext();
    try {
      List<Object> itemDataList = queryTransactionItems(
        industriesContext,
        contextId
      );
      System.debug(
        LoggingLevel.INFO,
        'queryTransactionItems → ' +
          (itemDataList == null
            ? 'null'
            : String.valueOf(itemDataList.size())) +
          ' raw SalesTransactionItem node(s)'
      );
      Map<Id, List<Object>> orderItemToDataPath = extractOrderItemPaths(
        itemDataList
      );
      Set<Id> orderItemIds = orderItemToDataPath.keySet();
      System.debug(
        LoggingLevel.INFO,
        'extractOrderItemPaths → ' +
          orderItemIds.size() +
          ' OrderItem(s): ' +
          orderItemIds
      );

      if (orderItemIds.isEmpty()) {
        System.debug(
          LoggingLevel.INFO,
          'PromoCodePricingPreHook: no OrderItems in pricing context — returning SUCCESS no-op.'
        );
        return buildResponse(
          RevSignaling.TransactionStatus.SUCCESS,
          'PromoCodePricingPreHook: no OrderItems in pricing context.'
        );
      }

      Map<Id, Decimal> adjustmentByOrderItem = aggregateAdjustments(
        orderItemIds
      );
      System.debug(
        LoggingLevel.INFO,
        'aggregateAdjustments → ' + adjustmentByOrderItem
      );
      List<Map<String, Object>> nodeUpdates = buildNodeUpdates(
        orderItemIds,
        orderItemToDataPath,
        adjustmentByOrderItem
      );
      System.debug(
        LoggingLevel.INFO,
        'buildNodeUpdates → ' + nodeUpdates.size() + ' node update(s)'
      );
      System.debug(
        LoggingLevel.DEBUG,
        'nodeUpdates payload: ' + JSON.serializePretty(nodeUpdates)
      );
      submitContextUpdates(industriesContext, contextId, nodeUpdates);

      String summary = summarizeResult(
        adjustmentByOrderItem.size(),
        nodeUpdates.size()
      );
      System.debug(
        LoggingLevel.INFO,
        '=== PromoCodePricingPreHook: SUCCESS — ' + summary + ' ==='
      );
      return buildResponse(RevSignaling.TransactionStatus.SUCCESS, summary);
    } catch (Exception e) {
      System.debug(
        LoggingLevel.ERROR,
        '=== PromoCodePricingPreHook: EXCEPTION === ' +
          e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\nLine: ' +
          e.getLineNumber() +
          '\nStack:\n' +
          e.getStackTraceString()
      );
      return buildResponse(
        RevSignaling.TransactionStatus.FAILED,
        'PromoCodePricingPreHook error: ' +
          e.getTypeName() +
          ' — ' +
          e.getMessage()
      );
    }
  }

  private static List<Object> queryTransactionItems(
    Context.IndustriesContext industriesContext,
    String contextId
  ) {
    Map<String, Object> queryInput = new Map<String, Object>{
      'contextId' => contextId,
      'tags' => new List<String>{ 'SalesTransactionItem' }
    };
    System.debug(
      LoggingLevel.DEBUG,
      'queryTags input: ' + JSON.serialize(queryInput)
    );
    Map<String, Object> rawResponse = industriesContext.queryTags(queryInput);
    System.debug(
      LoggingLevel.DEBUG,
      'queryTags raw response: ' +
      (rawResponse == null ? 'null' : JSON.serializePretty(rawResponse))
    );
    Map<String, Object> queryResult = rawResponse == null
      ? null
      : (Map<String, Object>) rawResponse.get('queryResult');
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
    if (nodeUpdates == null || nodeUpdates.isEmpty()) {
      System.debug(
        LoggingLevel.INFO,
        'submitContextUpdates: nothing to submit (null/empty list) — no-op.'
      );
      return;
    }
    Map<String, Object> updateInput = new Map<String, Object>{
      'contextId' => contextId,
      'nodePathAndAttributes' => nodeUpdates
    };
    System.debug(
      LoggingLevel.INFO,
      '--- PromoCodePricingPreHook: SUBMITTING CONTEXT UPDATE (' +
        nodeUpdates.size() +
        ' nodes) ---'
    );
    System.debug(
      LoggingLevel.DEBUG,
      'updateContextAttributes input: ' + JSON.serializePretty(updateInput)
    );
    industriesContext.updateContextAttributes(updateInput);
    System.debug(
      LoggingLevel.INFO,
      'updateContextAttributes call returned without exception.'
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
  private static Map<Id, List<Object>> extractOrderItemPaths(
    List<Object> itemDataList
  ) {
    Map<Id, List<Object>> result = new Map<Id, List<Object>>();
    if (itemDataList == null) {
      System.debug(
        LoggingLevel.WARN,
        'extractOrderItemPaths: itemDataList is null — returning empty map.'
      );
      return result;
    }
    Integer idx = -1;
    for (Object itemObj : itemDataList) {
      idx++;
      Map<String, Object> itemNode = (Map<String, Object>) itemObj;
      List<Object> dataPath = (List<Object>) itemNode.get('dataPath');
      System.debug(
        LoggingLevel.DEBUG,
        'node[' +
          idx +
          '] dataPath=' +
          dataPath +
          ' tagValue=' +
          itemNode.get('tagValue')
      );
      Map<String, Object> tags = (Map<String, Object>) itemNode.get('tagValue');
      if (tags == null || !tags.containsKey('LineItem')) {
        System.debug(
          LoggingLevel.DEBUG,
          'node[' + idx + '] skipped: no LineItem tag.'
        );
        continue;
      }
      Object lineItemEntry = tags.get('LineItem');
      if (!(lineItemEntry instanceof Map<String, Object>)) {
        System.debug(
          LoggingLevel.WARN,
          'node[' +
            idx +
            '] skipped: LineItem entry not a Map — actual=' +
            lineItemEntry
        );
        continue;
      }
      Map<String, Object> lineItemTag = (Map<String, Object>) lineItemEntry;
      Object dmlStatus = lineItemTag.get('dmlStatus');
      if (
        dmlStatus != null &&
        String.valueOf(dmlStatus).equalsIgnoreCase('DELETED')
      ) {
        System.debug(
          LoggingLevel.INFO,
          'node[' + idx + '] skipped: dmlStatus=DELETED.'
        );
        continue;
      }
      Object oiIdObj = lineItemTag.get('tagValue');
      if (oiIdObj == null) {
        System.debug(
          LoggingLevel.DEBUG,
          'node[' + idx + '] skipped: LineItem.tagValue is null.'
        );
        continue;
      }
      // In-flight pricing context can carry LineItem.tagValue as a reference string
      // (e.g., 'refChapterItem0') before items are committed to OrderItem records.
      // Casting that to Id throws; skip and rely on the post-commit pricing pass.
      String oiIdStr = String.valueOf(oiIdObj);
      if (oiIdStr.startsWith('ref')) {
        System.debug(
          LoggingLevel.INFO,
          'node[' +
            idx +
            '] skipped: unresolved ref tagValue=' +
            oiIdStr +
            ' (item not yet committed).'
        );
        continue;
      }
      Id orderItemId = (Id) oiIdStr;
      System.debug(
        LoggingLevel.INFO,
        'node[' + idx + '] kept: OrderItem=' + orderItemId
      );
      result.put(orderItemId, dataPath);
    }
    System.debug(
      LoggingLevel.INFO,
      'extractOrderItemPaths: kept ' +
        result.size() +
        ' of ' +
        itemDataList.size() +
        ' raw nodes.'
    );
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
    if (orderItemIds == null || orderItemIds.isEmpty()) {
      System.debug(
        LoggingLevel.DEBUG,
        'aggregateAdjustments: empty/null orderItemIds — skipping SOQL.'
      );
      return result;
    }
    List<Promo_Code_Item__c> pcis = [
      SELECT Order_Item__c, Applied_Discount_Amount__c
      FROM Promo_Code_Item__c
      WHERE Order_Item__c IN :orderItemIds AND Status__c = 'Pending'
    ];
    System.debug(
      LoggingLevel.INFO,
      'aggregateAdjustments: SOQL returned ' +
        pcis.size() +
        ' Pending PCI(s) for ' +
        orderItemIds.size() +
        ' OrderItem(s).'
    );
    for (Promo_Code_Item__c pci : pcis) {
      Decimal current = result.get(pci.Order_Item__c);
      Decimal amount = pci.Applied_Discount_Amount__c == null
        ? 0
        : pci.Applied_Discount_Amount__c;
      result.put(pci.Order_Item__c, (current == null ? 0 : current) + amount);
    }
    System.debug(LoggingLevel.DEBUG, 'aggregateAdjustments result: ' + result);
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
    Set<Id> orderItemIds,
    Map<Id, List<Object>> orderItemToDataPath,
    Map<Id, Decimal> adjustmentByOrderItem
  ) {
    List<Map<String, Object>> nodeUpdates = new List<Map<String, Object>>();
    if (orderItemIds == null)
      return nodeUpdates;
    for (Id oiId : orderItemIds) {
      List<Object> fullPath = orderItemToDataPath == null
        ? null
        : orderItemToDataPath.get(oiId);
      if (fullPath == null || fullPath.size() < 2) {
        System.debug(
          LoggingLevel.WARN,
          'buildNodeUpdates: skipping OrderItem ' +
            oiId +
            ' — malformed dataPath ' +
            fullPath
        );
        continue;
      }
      // Copy then strip the leading contextId — don't mutate the caller's list.
      List<Object> nodePath = new List<Object>(fullPath);
      nodePath.remove(0);

      Decimal adjustment = adjustmentByOrderItem != null &&
        adjustmentByOrderItem.containsKey(oiId)
        ? adjustmentByOrderItem.get(oiId)
        : 0;
      System.debug(
        LoggingLevel.DEBUG,
        'buildNodeUpdates: OrderItem=' +
          oiId +
          ' Promotion_Value__c=' +
          adjustment +
          ' nodePath=' +
          nodePath
      );

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
