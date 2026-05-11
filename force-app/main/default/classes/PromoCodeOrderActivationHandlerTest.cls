/**
 * Tests for PromoCodeOrderActivationHandler — Pending -> Confirmed PCI flips and parent
 * Confirmed_Usage_Count__c increments on Order Status -> Activated.
 *
 * Style matches the rest of the promo-code test suite: factory-based, @IsTest(SeeAllData=true)
 * to avoid Product2 insert-flow blocks, inline assertions.
 */
@IsTest(SeeAllData=true)
private class PromoCodeOrderActivationHandlerTest {
  private static final String CURRENCY_ISO = 'USD';

  // -----------------------------------------------------------------------
  // Happy path
  // -----------------------------------------------------------------------

  @IsTest
  static void activation_confirmsPendingPcis_andIncrementsParent() {
    Setup s = setupOrderWithPendingPci(40);
    if (s == null)
      return;
    Decimal beforeCount = currentUsageCount(s.code.Id);

    Test.startTest();
    s.ord.Status = 'Activated';
    update s.ord;
    Test.stopTest();

    Promo_Code_Item__c pciAfter = [
      SELECT Status__c, Confirmed_Date__c
      FROM Promo_Code_Item__c
      WHERE Id = :s.pci.Id
    ];
    System.assertEquals(
      'Confirmed',
      pciAfter.Status__c,
      'PCI should flip to Confirmed'
    );
    System.assertNotEquals(
      null,
      pciAfter.Confirmed_Date__c,
      'Confirmed_Date__c should be set'
    );

    Decimal afterCount = currentUsageCount(s.code.Id);
    System.assertEquals(
      (beforeCount == null ? 0 : beforeCount) + 1,
      afterCount,
      'Parent Confirmed_Usage_Count__c should increment by 1'
    );
  }

  @IsTest
  static void activation_multiplePcisOnSameCode_incrementsByCount() {
    Setup s = setupOrderWithPendingPci(40);
    if (s == null)
      return;
    // Add a second OrderItem + PCI for the same parent code.
    List<OrderItem> moreOis = PromoCodeTestDataFactory.addItemsFromExistingMembershipProducts(
      s.ord,
      2
    );
    if (moreOis.size() < 1) {
      return;
    }
    Promo_Code_Item__c secondPci = PromoCodeTestDataFactory.newPendingPci(
      s.code,
      moreOis[0],
      s.member,
      15
    );
    Decimal beforeCount = currentUsageCount(s.code.Id);

    Test.startTest();
    s.ord.Status = 'Activated';
    update s.ord;
    Test.stopTest();

    Integer confirmed = [
      SELECT COUNT()
      FROM Promo_Code_Item__c
      WHERE Order__c = :s.ord.Id AND Status__c = 'Confirmed'
    ];
    System.assert(
      confirmed >= 2,
      'Both PCIs on the activated Order should be Confirmed; got ' + confirmed
    );
    Decimal afterCount = currentUsageCount(s.code.Id);
    System.assertEquals(
      (beforeCount == null ? 0 : beforeCount) + confirmed,
      afterCount,
      'Parent count should increment by the number of newly-confirmed PCIs'
    );
  }

  // -----------------------------------------------------------------------
  // No-op paths
  // -----------------------------------------------------------------------

  @IsTest
  static void activation_noPendingPcis_isNoOp() {
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
      return;

    Test.startTest();
    ord.Status = 'Activated';
    update ord;
    Test.stopTest();

    // No PCIs exist; this just proves the handler doesn't NPE on an Order with no Pending PCIs.
    System.assertEquals(
      0,
      [
        SELECT COUNT()
        FROM Promo_Code_Item__c
        WHERE Order_Item__r.OrderId = :ord.Id
      ]
    );
  }

  @IsTest
  static void nonActivationUpdate_doesNotConfirm() {
    Setup s = setupOrderWithPendingPci(40);
    if (s == null)
      return;
    Decimal beforeCount = currentUsageCount(s.code.Id);

    Test.startTest();
    // Touch a non-Status field — handler should not run any confirmation logic.
    s.ord.EffectiveDate = Date.today().addDays(1);
    update s.ord;
    Test.stopTest();

    Promo_Code_Item__c pciAfter = [
      SELECT Status__c
      FROM Promo_Code_Item__c
      WHERE Id = :s.pci.Id
    ];
    System.assertEquals(
      'Pending',
      pciAfter.Status__c,
      'PCI should remain Pending when Status did not transition'
    );
    System.assertEquals(beforeCount, currentUsageCount(s.code.Id));
  }

  // -----------------------------------------------------------------------
  // Re-validation failures block activation via addError
  // -----------------------------------------------------------------------

  @IsTest
  static void activation_expiredCode_blocksWithAddError() {
    Setup s = setupOrderWithPendingPci(40);
    if (s == null)
      return;
    // Expire the parent code AFTER the PCI was reserved.
    s.code.Effective_End_Date__c = Datetime.now().addMinutes(-1);
    update s.code;
    Decimal beforeCount = currentUsageCount(s.code.Id);

    Test.startTest();
    Boolean caught = false;
    try {
      s.ord.Status = 'Activated';
      update s.ord;
    } catch (DmlException de) {
      caught = true;
      System.assert(
        de.getMessage().contains('expired') ||
        de.getMessage().contains('no longer valid'),
        'Expected expiry error; got: ' + de.getMessage()
      );
    }
    Test.stopTest();

    System.assert(caught, 'Expected DmlException from addError to be thrown');
    Promo_Code_Item__c pciAfter = [
      SELECT Status__c
      FROM Promo_Code_Item__c
      WHERE Id = :s.pci.Id
    ];
    System.assertEquals(
      'Pending',
      pciAfter.Status__c,
      'PCI should remain Pending after blocked activation'
    );
    System.assertEquals(
      beforeCount,
      currentUsageCount(s.code.Id),
      'Parent count must not increment on a blocked activation'
    );
  }

  @IsTest
  static void activation_inactiveCode_blocksWithAddError() {
    Setup s = setupOrderWithPendingPci(40);
    if (s == null)
      return;
    s.code.Status__c = 'Draft';
    update s.code;

    Test.startTest();
    Boolean caught = false;
    try {
      s.ord.Status = 'Activated';
      update s.ord;
    } catch (DmlException de) {
      caught = true;
      System.assert(
        de.getMessage().contains('Active') ||
        de.getMessage().contains('no longer valid'),
        'Expected inactive-code error; got: ' + de.getMessage()
      );
    }
    Test.stopTest();

    System.assert(caught, 'Expected DmlException from addError to be thrown');
  }

  // -----------------------------------------------------------------------
  // Pure validator
  // -----------------------------------------------------------------------

  @IsTest
  static void validationFailureReason_inactiveCode() {
    Promo_Code__c c = new Promo_Code__c(Status__c = 'Draft');
    String reason = PromoCodeOrderActivationHandler.validationFailureReason(
      c,
      System.now()
    );
    System.assert(
      reason != null && reason.contains('Active'),
      'Inactive code should fail; got: ' + reason
    );
  }

  @IsTest
  static void validationFailureReason_expiredCode() {
    Promo_Code__c c = new Promo_Code__c(
      Status__c = 'Active',
      Effective_End_Date__c = Datetime.now().addMinutes(-1)
    );
    String reason = PromoCodeOrderActivationHandler.validationFailureReason(
      c,
      System.now()
    );
    System.assert(
      reason != null && reason.contains('expired'),
      'Expired code should fail; got: ' + reason
    );
  }

  @IsTest
  static void validationFailureReason_notYetEffective() {
    Promo_Code__c c = new Promo_Code__c(
      Status__c = 'Active',
      Effective_Start_Date__c = Datetime.now().addDays(1)
    );
    String reason = PromoCodeOrderActivationHandler.validationFailureReason(
      c,
      System.now()
    );
    System.assert(
      reason != null && reason.contains('not yet'),
      'Future-dated code should fail; got: ' + reason
    );
  }

  @IsTest
  static void validationFailureReason_valid_returnsNull() {
    Promo_Code__c c = new Promo_Code__c(
      Status__c = 'Active',
      Effective_Start_Date__c = Datetime.now().addDays(-1),
      Effective_End_Date__c = Datetime.now().addDays(1)
    );
    System.assertEquals(
      null,
      PromoCodeOrderActivationHandler.validationFailureReason(c, System.now())
    );
  }

  // -----------------------------------------------------------------------
  // helpers
  // -----------------------------------------------------------------------

  private class Setup {
    Account member;
    Order ord;
    OrderItem oi;
    Promo_Code__c code;
    Promo_Code_Item__c pci;
  }

  private static Setup setupOrderWithPendingPci(Decimal pciAmount) {
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
    Promo_Code__c code = PromoCodeTestDataFactory.newActivePercentCode(
      'ACTV_' + PromoCodeTestDataFactory.unique(''),
      CURRENCY_ISO,
      10
    );
    Promo_Code_Item__c pci = PromoCodeTestDataFactory.newPendingPci(
      code,
      ois[0],
      member,
      pciAmount
    );
    Setup s = new Setup();
    s.member = member;
    s.ord = ord;
    s.oi = ois[0];
    s.code = code;
    s.pci = pci;
    return s;
  }

  private static Decimal currentUsageCount(Id codeId) {
    return [
      SELECT Confirmed_Usage_Count__c
      FROM Promo_Code__c
      WHERE Id = :codeId
    ]
    .Confirmed_Usage_Count__c;
  }
}
