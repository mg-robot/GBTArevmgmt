/**
 * Schedulable wrapper around `PromoCodeReservationCleanupBatch`. Designed to run every 15
 * minutes via System.schedule. Implements docs/promo-code/checkout-apply-flow.md §9.
 *
 * Bootstrap (one-time, run as System Administrator from anonymous Apex):
 *
 *   PromoCodeReservationCleanupScheduler.scheduleEveryFifteenMinutes();
 *
 * This installs four jobs (`:00`, `:15`, `:30`, `:45` of every hour) because the standard
 * Apex cron syntax has no native "every N minutes" expression. Each job calls `execute()`,
 * which kicks off a fresh batch.
 *
 * To remove later: query `CronTrigger` for `CronJobDetail.Name LIKE 'PromoCodeReservationCleanup%'`
 * and call `System.abortJob(id)` for each.
 */
public with sharing class PromoCodeReservationCleanupScheduler implements Schedulable {
  @TestVisible
  static final String JOB_NAME_PREFIX = 'PromoCodeReservationCleanup';
  @TestVisible
  static final Integer DEFAULT_BATCH_SIZE = 200;

  public void execute(SchedulableContext sc) {
    System.debug(
      LoggingLevel.INFO,
      '=== PromoCodeReservationCleanupScheduler fired at ' +
        System.now() +
        ' — kicking off cleanup batch ==='
    );
    Database.executeBatch(
      new PromoCodeReservationCleanupBatch(),
      DEFAULT_BATCH_SIZE
    );
  }

  /**
   * Installs four schedules at :00, :15, :30, :45 of every hour. Idempotent in spirit — safe to
   * re-invoke; existing jobs with the same name will collide and throw, so abort first if you
   * need to re-bootstrap.
   *
   * Returns the list of CronTrigger Ids that were created.
   */
  public static List<Id> scheduleEveryFifteenMinutes() {
    List<Id> jobIds = new List<Id>();
    List<Integer> minutes = new List<Integer>{ 0, 15, 30, 45 };
    for (Integer m : minutes) {
      String cron = '0 ' + m + ' * * * ?';
      String jobName =
        JOB_NAME_PREFIX +
        ' ' +
        String.valueOf(m).leftPad(2, '0');
      jobIds.add(
        System.schedule(
          jobName,
          cron,
          new PromoCodeReservationCleanupScheduler()
        )
      );
    }
    System.debug(
      LoggingLevel.INFO,
      'scheduleEveryFifteenMinutes: installed jobs ' + jobIds
    );
    return jobIds;
  }
}
