/**
 * Tests for PromoCodeReservationCleanupScheduler — verifies that scheduling the job registers
 * with the platform scheduler and that `execute()` runs without throwing.
 */
@IsTest
private class PromoCodeReservationCleanupSchedulerTest {
  @IsTest
  static void schedule_oneOff_registersCronTrigger() {
    // System.schedule a single one-off cron expression and confirm it lands.
    String jobName =
      'PromoCodeReservationCleanupTest_' + System.currentTimeMillis();
    String cron = '0 0 0 1 1 ? 2099'; // far-future to avoid actually firing
    Test.startTest();
    String jobId = System.schedule(
      jobName,
      cron,
      new PromoCodeReservationCleanupScheduler()
    );
    Test.stopTest();

    System.assertNotEquals(null, jobId, 'schedule should return a job Id');
    CronTrigger ct = [
      SELECT Id, CronExpression
      FROM CronTrigger
      WHERE Id = :jobId
    ];
    System.assertEquals(cron, ct.CronExpression);
  }

  @IsTest
  static void execute_kicksBatch_withoutThrowing() {
    Test.startTest();
    new PromoCodeReservationCleanupScheduler().execute(null);
    Test.stopTest();
    // No assertion target beyond "did not throw" — the batch's own test suite covers
    // the cleanup logic itself.
    System.assert(true);
  }
}
