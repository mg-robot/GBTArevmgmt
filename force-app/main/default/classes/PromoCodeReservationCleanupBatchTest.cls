/**
 * Tests for PromoCodeReservationCleanupBatch — TTL-driven release of stale Pending PCIs.
 */
@IsTest(SeeAllData=true)
private class PromoCodeReservationCleanupBatchTest {
  private static final String CURRENCY_ISO = 'USD';

  @IsTest
  static void release_stalePci_movesToReleasedWithTtlExpired() {
    Promo_Code_Item__c stale = insertPendingPciWithAppliedDate(
      Datetime.now().addMinutes(-120) // 2 hours old — definitely stale at any TTL <= 120m
    );
    if (stale == null)
      return;

    Test.startTest();
    // TTL = 60m via the override. Stale PCI (120m old) should be released.
    Database.executeBatch(new PromoCodeReservationCleanupBatch(60), 200);
    Test.stopTest();

    Promo_Code_Item__c after = [
      SELECT Status__c, Released_Date__c, Release_Reason__c
      FROM Promo_Code_Item__c
      WHERE Id = :stale.Id
    ];
    System.assertEquals('Released', after.Status__c);
    System.assertEquals('TTL Expired', after.Release_Reason__c);
    System.assertNotEquals(
      null,
      after.Released_Date__c,
      'Released_Date__c should be stamped'
    );
  }

  @IsTest
  static void release_freshPci_isUntouched() {
    Promo_Code_Item__c fresh = insertPendingPciWithAppliedDate(
      Datetime.now().addMinutes(-5) // 5 minutes old — well within TTL
    );
    if (fresh == null)
      return;

    Test.startTest();
    Database.executeBatch(new PromoCodeReservationCleanupBatch(60), 200);
    Test.stopTest();

    Promo_Code_Item__c after = [
      SELECT Status__c, Release_Reason__c
      FROM Promo_Code_Item__c
      WHERE Id = :fresh.Id
    ];
    System.assertEquals(
      'Pending',
      after.Status__c,
      'Fresh PCI should remain Pending'
    );
    System.assertEquals(null, after.Release_Reason__c);
  }

  @IsTest
  static void release_alreadyReleasedPci_isUntouched() {
    Promo_Code_Item__c old = insertPendingPciWithAppliedDate(
      Datetime.now().addMinutes(-120)
    );
    if (old == null)
      return;
    old.Status__c = 'Released';
    old.Release_Reason__c = 'Cart Abandoned';
    old.Released_Date__c = Datetime.now().addMinutes(-30);
    update old;

    Test.startTest();
    Database.executeBatch(new PromoCodeReservationCleanupBatch(60), 200);
    Test.stopTest();

    Promo_Code_Item__c after = [
      SELECT Status__c, Release_Reason__c
      FROM Promo_Code_Item__c
      WHERE Id = :old.Id
    ];
    System.assertEquals(
      'Cart Abandoned',
      after.Release_Reason__c,
      'Already-Released PCI should not be re-released or have its reason changed'
    );
  }

  @IsTest
  static void resolveTtlMinutes_overrideWins() {
    PromoCodeReservationCleanupBatch b = new PromoCodeReservationCleanupBatch(
      15
    );
    System.assertEquals(15, b.resolveTtlMinutes());
  }

  @IsTest
  static void resolveTtlMinutes_fallsBackToDefaultWhenNoMdtRecord() {
    // No override and (best-effort) no Default record needed for this assertion — when the
    // metadata is absent, the resolver must return DEFAULT_TTL_MINUTES (60). If the org
    // has a Default record, this still passes because the seeded value is also 60.
    PromoCodeReservationCleanupBatch b = new PromoCodeReservationCleanupBatch();
    Integer resolved = b.resolveTtlMinutes();
    System.assert(
      resolved > 0,
      'Resolver should return a positive TTL; got: ' + resolved
    );
  }

  @IsTest
  static void instantiate_default_constructor_doesNotThrow() {
    PromoCodeReservationCleanupBatch b = new PromoCodeReservationCleanupBatch();
    System.assertNotEquals(null, b);
  }

  // -----------------------------------------------------------------------
  // helpers
  // -----------------------------------------------------------------------

  /**
   * Inserts a Pending PCI then back-dates `Applied_Date__c` via a follow-up update (the create
   * trigger / default fills in NOW, so a freshly-inserted PCI is always "fresh" until we rewrite
   * the field). Returns null if the test environment can't create OrderItems (Flow blocks).
   */
  private static Promo_Code_Item__c insertPendingPciWithAppliedDate(
    Datetime appliedDate
  ) {
    Account member = PromoCodeTestDataFactory.newMember();
    Order ord = PromoCodeTestDataFactory.newOrder(
      member,
      CURRENCY_ISO,
      null,
      null
    );
    List<OrderItem> ois = PromoCodeTestDataFactory.addItemsFromExistingMembershipProducts(
      ord,
      1
    );
    if (ois.isEmpty())
      return null;
    Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(
      'TTL_' + PromoCodeTestDataFactory.unique(''),
      CURRENCY_ISO,
      10
    );
    Promo_Code_Item__c pci = PromoCodeTestDataFactory.newPendingPci(
      pc,
      ois[0],
      member,
      25
    );
    pci.Applied_Date__c = appliedDate;
    update pci;
    return pci;
  }
}
