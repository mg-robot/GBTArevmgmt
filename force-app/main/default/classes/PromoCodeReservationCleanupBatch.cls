/**
 * Cleanup batch — releases Pending `Promo_Code_Item__c` records whose `Applied_Date__c` is older
 * than the configured TTL. Implements docs/promo-code/checkout-apply-flow.md §9.
 *
 * Behavior:
 *   - TTL minutes are read from `Promo_Code_Setting__mdt.Default.Pending_TTL_Minutes__c`
 *     (default 60). The TTL can be tuned by editing the metadata record — no deploy required.
 *   - Each stale PCI: `Status__c -> Released`, `Released_Date__c -> NOW()`,
 *     `Release_Reason__c -> 'TTL Expired'`.
 *   - Releasing a PCI frees its reserved usage slot so other members can redeem the code
 *     (relevant for codes with a tight `Total_Usage_Limit__c`).
 *
 * Scheduled to run every 15 minutes by `PromoCodeReservationCleanupScheduler`. Can also be
 * invoked manually: `Database.executeBatch(new PromoCodeReservationCleanupBatch(), 200);`.
 */
public with sharing class PromoCodeReservationCleanupBatch implements Database.Batchable<SObject>, Database.Stateful {
  @TestVisible
  static final Integer DEFAULT_TTL_MINUTES = 60;
  @TestVisible
  static final String DEFAULT_SETTING_NAME = 'Default';

  /**
   * Override TTL at instantiation time (e.g., for ad-hoc cleanups). When null, the value from
   * the Custom Metadata record is used.
   */
  @TestVisible
  private Integer ttlMinutesOverride;
  @TestVisible
  private Integer releasedCount = 0;

  public PromoCodeReservationCleanupBatch() {
  }

  public PromoCodeReservationCleanupBatch(Integer ttlMinutesOverride) {
    this.ttlMinutesOverride = ttlMinutesOverride;
  }

  public Database.QueryLocator start(Database.BatchableContext bc) {
    Integer ttlMinutes = resolveTtlMinutes();
    Datetime cutoff = System.now().addMinutes(-ttlMinutes);
    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodeReservationCleanupBatch.start === TTL=' +
        ttlMinutes +
        'm, cutoff=' +
        cutoff
    );
    return Database.getQueryLocator(
      [
        SELECT Id, Status__c, Applied_Date__c
        FROM Promo_Code_Item__c
        WHERE Status__c = 'Pending' AND Applied_Date__c < :cutoff
      ]
    );
  }

  public void execute(
    Database.BatchableContext bc,
    List<Promo_Code_Item__c> scope
  ) {
    System.debug(
      LoggingLevel.INFO,
      'execute(): releasing ' + scope.size() + ' stale Pending PCI(s)'
    );
    Datetime nowDt = System.now();
    for (Promo_Code_Item__c pci : scope) {
      pci.Status__c = 'Released';
      pci.Released_Date__c = nowDt;
      pci.Release_Reason__c = 'TTL Expired';
    }
    update scope;
    releasedCount += scope.size();
  }

  public void finish(Database.BatchableContext bc) {
    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodeReservationCleanupBatch.finish === Released ' +
        releasedCount +
        ' PCI(s) total.'
    );
  }

  /**
   * Resolves the effective TTL: instance override -> Custom Metadata 'Default' record ->
   * hardcoded fallback. Surfaced @TestVisible for unit tests that need to assert the fallback
   * chain without depending on org metadata state.
   */
  @TestVisible
  private Integer resolveTtlMinutes() {
    if (ttlMinutesOverride != null && ttlMinutesOverride > 0) {
      return ttlMinutesOverride;
    }
    Promo_Code_Setting__mdt cfg = Promo_Code_Setting__mdt.getInstance(
      DEFAULT_SETTING_NAME
    );
    if (cfg == null || cfg.Pending_TTL_Minutes__c == null) {
      System.debug(
        LoggingLevel.WARN,
        'Promo_Code_Setting__mdt.Default missing or null TTL — using fallback ' +
          DEFAULT_TTL_MINUTES +
          'm.'
      );
      return DEFAULT_TTL_MINUTES;
    }
    return Integer.valueOf(cfg.Pending_TTL_Minutes__c);
  }
}
