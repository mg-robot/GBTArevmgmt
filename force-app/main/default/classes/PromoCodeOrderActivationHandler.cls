/**
 * Order Activation handler — flips Pending `Promo_Code_Item__c` records to Confirmed and
 * increments parent `Promo_Code__c.Confirmed_Usage_Count__c` when an Order's Status transitions
 * to Activated. Implements the design in docs/promo-code/checkout-apply-flow.md §8.
 *
 * Lifecycle:
 *   1. Detect Orders where Status just transitioned -> Activated (was not, now is)
 *   2. Load Pending PCIs for those Orders + their parent Promo_Code__c records
 *   3. Re-validate each unique parent code (Status = Active, NOW within effective window).
 *      If any code fails, `addError` on the Order(s) that referenced it — this rolls back the
 *      entire activation. The member/staff removes the bad code and retries.
 *   4. Pending -> Confirmed (set Confirmed_Date__c)
 *   5. SELECT parents FOR UPDATE; increment Confirmed_Usage_Count__c per parent
 *
 * Verbose `System.debug` instrumentation throughout matches the convention established by
 * PromoCodePricingPreHook — INFO for pipeline milestones, DEBUG for per-record detail.
 */
public with sharing class PromoCodeOrderActivationHandler {
  @TestVisible
  private static final String STATUS_ACTIVATED = 'Activated';

  public void afterUpdate(List<Order> updated, Map<Id, Order> oldMap) {
    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodeOrderActivationHandler: afterUpdate entered (' +
        updated.size() +
        ' Orders in batch) ==='
    );

    Set<Id> activatedOrderIds = new Set<Id>();
    Map<Id, Order> activatedById = new Map<Id, Order>();
    for (Order o : updated) {
      Order prev = oldMap == null ? null : oldMap.get(o.Id);
      if (
        o.Status == STATUS_ACTIVATED &&
        (prev == null ||
        prev.Status != STATUS_ACTIVATED)
      ) {
        activatedOrderIds.add(o.Id);
        activatedById.put(o.Id, o);
      }
    }
    if (activatedOrderIds.isEmpty()) {
      System.debug(
        LoggingLevel.DEBUG,
        'No Status transitions to Activated in this update batch — exiting.'
      );
      return;
    }
    System.debug(
      LoggingLevel.INFO,
      'Activated Order Ids: ' + activatedOrderIds
    );

    // Pull Pending PCIs + parent code data in one go.
    List<Promo_Code_Item__c> pendingPcis = [
      SELECT
        Id,
        Promo_Code__c,
        Promo_Code__r.Code__c,
        Promo_Code__r.Display_Name__c,
        Promo_Code__r.Status__c,
        Promo_Code__r.Effective_Start_Date__c,
        Promo_Code__r.Effective_End_Date__c,
        Order_Item__r.OrderId
      FROM Promo_Code_Item__c
      WHERE
        Order_Item__r.OrderId IN :activatedOrderIds
        AND Status__c = 'Pending'
    ];
    System.debug(
      LoggingLevel.INFO,
      'Pending PCIs loaded: ' + pendingPcis.size()
    );

    if (pendingPcis.isEmpty()) {
      System.debug(
        LoggingLevel.INFO,
        'No Pending PCIs for the activated Orders — nothing to confirm.'
      );
      return;
    }

    // Re-validate parent codes defensively. If a code expired between Apply and Activation,
    // block the Order with addError so the bad code can be removed and the activation retried.
    if (!revalidateAndMaybeAddErrors(pendingPcis, activatedById, oldMap)) {
      System.debug(
        LoggingLevel.WARN,
        'Re-validation failed — activation blocked via addError; aborting handler.'
      );
      return;
    }

    // Confirm PCIs and tally per-parent increments.
    Map<Id, Integer> incrementByCode = new Map<Id, Integer>();
    Datetime nowDt = System.now();
    for (Promo_Code_Item__c pci : pendingPcis) {
      pci.Status__c = 'Confirmed';
      pci.Confirmed_Date__c = nowDt;
      Integer current = incrementByCode.get(pci.Promo_Code__c);
      incrementByCode.put(
        pci.Promo_Code__c,
        (current == null ? 0 : current) + 1
      );
    }
    System.debug(
      LoggingLevel.INFO,
      'Confirming ' +
        pendingPcis.size() +
        ' PCI(s) across ' +
        incrementByCode.size() +
        ' parent code(s); increments=' +
        incrementByCode
    );
    update pendingPcis;

    // Lock parents FOR UPDATE before incrementing — guards against concurrent activations
    // on hot codes (e.g., sponsor codes with many simultaneous redemptions).
    List<Promo_Code__c> parents = [
      SELECT Id, Confirmed_Usage_Count__c, Code__c
      FROM Promo_Code__c
      WHERE Id IN :incrementByCode.keySet()
      FOR UPDATE
    ];
    for (Promo_Code__c p : parents) {
      Decimal before = p.Confirmed_Usage_Count__c == null
        ? 0
        : p.Confirmed_Usage_Count__c;
      Decimal after = before + incrementByCode.get(p.Id);
      System.debug(
        LoggingLevel.INFO,
        'Promo_Code ' +
          p.Code__c +
          ' Confirmed_Usage_Count__c: ' +
          before +
          ' -> ' +
          after
      );
      p.Confirmed_Usage_Count__c = after;
    }
    update parents;

    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodeOrderActivationHandler: SUCCESS — ' +
        pendingPcis.size() +
        ' PCI(s) confirmed, ' +
        parents.size() +
        ' parent counter(s) incremented ==='
    );
  }

  /**
   * Re-validates every unique parent code referenced by the Pending PCIs. If any parent fails,
   * calls `addError` on every Order in the activation batch that references that code. Returns
   * false if any errors were added (caller should abort), true otherwise.
   */
  private Boolean revalidateAndMaybeAddErrors(
    List<Promo_Code_Item__c> pendingPcis,
    Map<Id, Order> activatedById,
    Map<Id, Order> oldMap
  ) {
    Datetime nowDt = System.now();
    Map<Id, Set<Id>> codeToOrderIds = new Map<Id, Set<Id>>();
    Map<Id, Promo_Code__c> codeById = new Map<Id, Promo_Code__c>();

    for (Promo_Code_Item__c pci : pendingPcis) {
      if (pci.Promo_Code__c == null)
        continue;
      Id codeId = pci.Promo_Code__c;
      Id orderId = pci.Order_Item__r.OrderId;
      if (!codeToOrderIds.containsKey(codeId)) {
        codeToOrderIds.put(codeId, new Set<Id>());
        // Snapshot the parent fields (already queried via Promo_Code__r) for re-validation.
        Promo_Code__c snapshot = new Promo_Code__c(
          Id = codeId,
          Code__c = pci.Promo_Code__r.Code__c,
          Display_Name__c = pci.Promo_Code__r.Display_Name__c,
          Status__c = pci.Promo_Code__r.Status__c,
          Effective_Start_Date__c = pci.Promo_Code__r.Effective_Start_Date__c,
          Effective_End_Date__c = pci.Promo_Code__r.Effective_End_Date__c
        );
        codeById.put(codeId, snapshot);
      }
      codeToOrderIds.get(codeId).add(orderId);
    }

    Boolean anyErrors = false;
    for (Id codeId : codeById.keySet()) {
      Promo_Code__c code = codeById.get(codeId);
      String reason = validationFailureReason(code, nowDt);
      if (reason == null) {
        System.debug(
          LoggingLevel.DEBUG,
          'Re-validation passed for code ' + code.Code__c
        );
        continue;
      }
      anyErrors = true;
      String displayLabel = String.isNotBlank(code.Display_Name__c)
        ? code.Display_Name__c + ' (' + code.Code__c + ')'
        : code.Code__c;
      String message =
        'Promo code "' +
        displayLabel +
        '" is no longer valid: ' +
        reason +
        '. Remove the code and retry activation.';
      System.debug(
        LoggingLevel.WARN,
        'Re-validation FAILED for code ' +
          code.Code__c +
          ': ' +
          reason +
          ' — adding error to Orders ' +
          codeToOrderIds.get(codeId)
      );
      for (Id orderId : codeToOrderIds.get(codeId)) {
        Order o = activatedById.get(orderId);
        if (o != null) {
          o.addError(message);
        }
      }
    }
    return !anyErrors;
  }

  /**
   * Returns null if the code passes re-validation, otherwise a short failure reason suitable for
   * concatenating into a user-facing error message.
   */
  @TestVisible
  private static String validationFailureReason(
    Promo_Code__c code,
    Datetime nowDt
  ) {
    if (code.Status__c != 'Active') {
      return 'code is no longer Active';
    }
    if (
      code.Effective_Start_Date__c != null &&
      nowDt < code.Effective_Start_Date__c
    ) {
      return 'code is not yet effective';
    }
    if (
      code.Effective_End_Date__c != null &&
      nowDt > code.Effective_End_Date__c
    ) {
      return 'code has expired';
    }
    return null;
  }
}
