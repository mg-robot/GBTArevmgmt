/**
 * Tests for PromoCodeService — covers the createBulk happy paths (Percent, Amount,
 * Activate Now vs Save as Draft, multi-currency), composite-uniqueness pre-check, input
 * validation guards, and validation-rule trips (lock-after-create, status transition,
 * require-combination-group). Includes a runAs() coverage check using the Promo_Code_Manager
 * permission set to confirm non-admin staff can execute the service.
 */
@IsTest
private class PromoCodeServiceTest {
  private static PromoCodeService.PromoCodeInput baseInput() {
    PromoCodeService.PromoCodeInput inp = new PromoCodeService.PromoCodeInput();
    inp.code = 'TESTCODE';
    inp.displayName = 'Test Code';
    inp.discountType = 'Percent';
    inp.percentValue = 10;
    inp.percentCurrencies = new List<String>{ UserInfo.getDefaultCurrency() };
    inp.effectiveStart = Datetime.now();
    inp.effectiveEnd = Datetime.now().addDays(30);
    inp.combinable = true;
    inp.combinationGroup = 'General';
    inp.productScopeType = 'All Items';
    inp.approvalRequired = false;
    inp.activateImmediately = false;
    return inp;
  }

  private static User createManagerUser() {
    Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
    User u = new User(
      Username = 'pcmtest_' +
        System.currentTimeMillis() +
        '@example.invalid.test',
      Email = 'pcmtest@example.invalid',
      FirstName = 'Test',
      LastName = 'Manager',
      Alias = 'pcmt',
      TimeZoneSidKey = 'America/Los_Angeles',
      LocaleSidKey = 'en_US',
      EmailEncodingKey = 'UTF-8',
      LanguageLocaleKey = 'en_US',
      ProfileId = p.Id
    );
    insert u;
    PermissionSet ps = [
      SELECT Id
      FROM PermissionSet
      WHERE Name = 'Promo_Code_Manager'
      LIMIT 1
    ];
    insert new PermissionSetAssignment(
      AssigneeId = u.Id,
      PermissionSetId = ps.Id
    );
    return u;
  }

  @IsTest
  static void getActiveCurrencies_returnsAtLeastOne() {
    Test.startTest();
    List<String> currencies = PromoCodeService.getActiveCurrencies();
    Test.stopTest();
    System.assert(
      !currencies.isEmpty(),
      'Expected at least one active currency'
    );
  }

  @IsTest
  static void searchProducts_shortTermReturnsEmpty() {
    List<PromoCodeService.ProductOption> hits = PromoCodeService.searchProducts(
      'a'
    );
    System.assert(hits.isEmpty(), 'Sub-2-char terms should return no hits');
  }

  @IsTest
  static void checkCodeUniqueness_noConflictReturnsEmpty() {
    List<String> conflicts = PromoCodeService.checkCodeUniqueness('NEVERUSED');
    System.assert(conflicts.isEmpty());
  }

  @IsTest
  static void checkCodeUniqueness_returnsConflictCurrencies() {
    PromoCodeService.createBulk(baseInput());

    Test.startTest();
    List<String> conflicts = PromoCodeService.checkCodeUniqueness('TESTCODE');
    Test.stopTest();

    System.assert(
      !conflicts.isEmpty(),
      'Expected at least one conflicting currency for existing code'
    );
  }

  @IsTest
  static void checkCodeUniqueness_blankInputReturnsEmpty() {
    System.assert(PromoCodeService.checkCodeUniqueness('').isEmpty());
    System.assert(PromoCodeService.checkCodeUniqueness(null).isEmpty());
  }

  @IsTest
  static void searchProducts_returnsHitsWhenProductsExist() {
    Product2 p = new Product2(
      Name = 'WidgetPromoTest',
      ProductCode = 'WPT-PROMO-1',
      IsActive = true
    );
    try {
      insert p;
    } catch (Exception e) {
      // Org has a Flow ("Product: add to Price Books") that requires PricebookEntry.UnitPrice
      // on Product2 insert. If that Flow blocks in test context, skip — search path is still
      // exercised by the empty-result test above.
      return;
    }

    Test.startTest();
    List<PromoCodeService.ProductOption> hits = PromoCodeService.searchProducts(
      'Widget'
    );
    Test.stopTest();

    System.assert(
      !hits.isEmpty(),
      'Expected at least one product hit for "Widget"'
    );
    System.assertEquals('WidgetPromoTest', hits[0].name);
  }

  @IsTest
  static void createBulk_percentSuccess_defaultsToDraft() {
    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(baseInput());
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    System.assertEquals(1, r.createdRecordIds.size());
    System.assertEquals('Draft', r.status);
    Promo_Code__c saved = [
      SELECT Code__c, Discount_Type__c, Discount_Value__c, Status__c
      FROM Promo_Code__c
      WHERE Id = :r.createdRecordIds[0]
    ];
    System.assertEquals('TESTCODE', saved.Code__c);
    System.assertEquals('Percent', saved.Discount_Type__c);
    System.assertEquals(10, saved.Discount_Value__c);
    System.assertEquals('Draft', saved.Status__c);
  }

  @IsTest
  static void createBulk_activateImmediately_setsActive() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'ACTIVATENOW';
    inp.activateImmediately = true;

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    System.assertEquals('Active', r.status);
    Promo_Code__c saved = [
      SELECT Status__c
      FROM Promo_Code__c
      WHERE Id = :r.createdRecordIds[0]
    ];
    System.assertEquals('Active', saved.Status__c);
  }

  @IsTest
  static void createBulk_amountSuccess() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'AMOUNTCODE';
    inp.discountType = 'Amount';
    inp.percentValue = null;
    inp.percentCurrencies = null;
    PromoCodeService.CurrencyAmount ca = new PromoCodeService.CurrencyAmount();
    ca.currencyIsoCode = UserInfo.getDefaultCurrency();
    ca.amount = 25;
    inp.amounts = new List<PromoCodeService.CurrencyAmount>{ ca };

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    System.assertEquals(1, r.createdRecordIds.size());
    Promo_Code__c saved = [
      SELECT Discount_Type__c, Discount_Value__c
      FROM Promo_Code__c
      WHERE Id = :r.createdRecordIds[0]
    ];
    System.assertEquals('Amount', saved.Discount_Type__c);
    System.assertEquals(25, saved.Discount_Value__c);
  }

  @IsTest
  static void createBulk_multiCurrency_singleTransaction() {
    List<String> isos = PromoCodeService.getActiveCurrencies();
    if (isos.size() < 2) {
      return;
    }
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'MULTICURR';
    inp.percentCurrencies = isos;

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    System.assertEquals(isos.size(), r.createdRecordIds.size());
    Integer count = [
      SELECT COUNT()
      FROM Promo_Code__c
      WHERE Code__c = 'MULTICURR'
    ];
    System.assertEquals(isos.size(), count);
  }

  @IsTest
  static void createBulk_invalidPercentRejected() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.percentValue = 150;

    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    System.assertEquals(false, r.success);
    System.assert(r.errorMessage.contains('between 0 and 100'));
  }

  @IsTest
  static void createBulk_amountWithoutAmountsRejected() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.discountType = 'Amount';
    inp.amounts = null;

    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    System.assertEquals(false, r.success);
    System.assert(r.errorMessage.contains('currency-amount'));
  }

  @IsTest
  static void createBulk_missingRequiredFieldsRejected() {
    PromoCodeService.PromoCodeInput inp = new PromoCodeService.PromoCodeInput();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    System.assertEquals(false, r.success);
    System.assert(r.errorMessage.contains('Missing required'));
  }

  @IsTest
  static void createBulk_duplicateCodeBlocked() {
    Boolean isMC =
      Schema.getGlobalDescribe().containsKey('CurrencyType') &&
      Schema.SObjectType.Promo_Code__c.fields.getMap()
        .containsKey('currencyisocode');
    if (!isMC) {
      return;
    }
    PromoCodeService.createBulk(baseInput());

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(baseInput());
    Test.stopTest();

    System.assertEquals(false, r.success);
    System.assertNotEquals(null, r.conflictCurrencies);
    System.assert(!r.conflictCurrencies.isEmpty());
  }

  @IsTest
  static void vr_requireCombinationGroup_blocksMissingGroup() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'NOGROUP';
    inp.combinable = true;
    inp.combinationGroup = null;

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(false, r.success);
    System.assert(
      r.errorMessage != null && r.errorMessage.contains('Combination Group'),
      'Expected VR_PromoCode_RequireCombinationGroup; got: ' + r.errorMessage
    );
  }

  @IsTest
  static void vr_lockAfterCreate_blocksCoreFieldEdit() {
    User u = createManagerUser();
    Promo_Code__c rec;
    System.runAs(u) {
      PromoCodeService.PromoCodeInput inp = baseInput();
      inp.code = 'LOCKTEST';
      PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
      System.assertEquals(true, r.success, 'Setup failed: ' + r.errorMessage);
      rec = new Promo_Code__c(
        Id = r.createdRecordIds[0],
        Display_Name__c = 'Changed Name'
      );
    }

    Test.startTest();
    System.runAs(u) {
      try {
        update rec;
        System.assert(
          false,
          'Expected VR_PromoCode_Lock_After_Create to block the edit'
        );
      } catch (DmlException e) {
        System.assert(
          e.getMessage().contains('locked after the promo code is created'),
          'Unexpected error: ' + e.getMessage()
        );
      }
    }
    Test.stopTest();
  }

  @IsTest
  static void vr_statusTransition_blocksActiveToDraft() {
    User u = createManagerUser();
    Promo_Code__c rec;
    System.runAs(u) {
      PromoCodeService.PromoCodeInput inp = baseInput();
      inp.code = 'STATUSTRANS';
      inp.activateImmediately = true;
      PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
      System.assertEquals(true, r.success, 'Setup failed: ' + r.errorMessage);
      rec = new Promo_Code__c(Id = r.createdRecordIds[0], Status__c = 'Draft');
    }

    Test.startTest();
    System.runAs(u) {
      try {
        update rec;
        System.assert(
          false,
          'Expected VR_PromoCode_Status_Transitions to block Active->Draft'
        );
      } catch (DmlException e) {
        System.assert(
          e.getMessage().contains('Cannot move an Active'),
          'Unexpected error: ' + e.getMessage()
        );
      }
    }
    Test.stopTest();
  }

  @IsTest
  static void createBulk_defaultsApplicationLevelToPerOrder() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'DEFAULTLEVEL';
    inp.applicationLevel = null;

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    Promo_Code__c saved = [
      SELECT Application_Level__c
      FROM Promo_Code__c
      WHERE Id = :r.createdRecordIds[0]
    ];
    System.assertEquals(
      'Per Order',
      saved.Application_Level__c,
      'Service should default Application_Level__c to Per Order when input is blank'
    );
  }

  @IsTest
  static void createBulk_perLineLevel_persists() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'PERLINECODE';
    inp.applicationLevel = 'Per Line';
    inp.productScopeType = 'Product Family';
    inp.productFamilyScope = new List<String>{ 'Membership', 'Chapter' };

    Test.startTest();
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
    Promo_Code__c saved = [
      SELECT
        Application_Level__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c
      FROM Promo_Code__c
      WHERE Id = :r.createdRecordIds[0]
    ];
    System.assertEquals('Per Line', saved.Application_Level__c);
    System.assertEquals('Product Family', saved.Product_Scope_Type__c);
    System.assert(saved.Product_Family_Scope__c.contains('Membership'));
    System.assert(saved.Product_Family_Scope__c.contains('Chapter'));
  }

  @IsTest
  static void createBulk_bulkSafe_handles200CodesInSequence() {
    // Seed 200 distinct codes directly via DML, then exercise the service queries against them
    // to confirm bulk-safety of checkCodeUniqueness and the createBulk pre-insert duplicate scan.
    String iso = UserInfo.getDefaultCurrency();
    List<Promo_Code__c> seed = new List<Promo_Code__c>();
    for (Integer i = 0; i < 200; i++) {
      Promo_Code__c pc = new Promo_Code__c(
        Code__c = 'BULK' + i,
        Discount_Type__c = 'Percent',
        Discount_Value__c = 5,
        Status__c = 'Draft',
        Application_Level__c = 'Per Order',
        Product_Scope_Type__c = 'All Items',
        Combinable__c = true,
        Combination_Group__c = 'General',
        Display_Name__c = 'Bulk ' + i
      );
      if (
        Schema.SObjectType.Promo_Code__c.fields.getMap()
          .containsKey('currencyisocode')
      ) {
        pc.put('CurrencyIsoCode', iso);
      }
      seed.add(pc);
    }

    Test.startTest();
    insert seed;
    // Confirm the conflict-check query handles bulk
    List<String> conflicts = PromoCodeService.checkCodeUniqueness('BULK100');
    // Service createBulk for a fresh non-conflicting code still succeeds after 200 records
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'POSTBULK';
    PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
    Test.stopTest();

    System.assert(!conflicts.isEmpty(), 'Expected conflict for seeded BULK100');
    System.assertEquals(
      true,
      r.success,
      'createBulk after 200 seeded codes failed: ' + r.errorMessage
    );
  }

  @IsTest
  static void createBulk_runAsManagerUser_canCreate() {
    User u = createManagerUser();

    Test.startTest();
    System.runAs(u) {
      PromoCodeService.PromoCodeInput inp = baseInput();
      inp.code = 'RUNASTEST';
      PromoCodeService.CreateResult r = PromoCodeService.createBulk(inp);
      System.assertEquals(true, r.success, 'errorMessage: ' + r.errorMessage);
      System.assertEquals(1, r.createdRecordIds.size());
    }
    Test.stopTest();
  }

  // ===================================================================================
  // loadDefinition — Open in Setup Wizard from a record
  // ===================================================================================

  @IsTest
  static void loadDefinition_percentCode_populatesAllFields() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'LOADPCT';
    inp.terms = 'Test terms';
    inp.totalLimit = 100;
    inp.perMemberLimit = 5;
    inp.memberTypeScope = new List<String>{ 'Allied', 'Direct' };
    PromoCodeService.CreateResult create = PromoCodeService.createBulk(inp);
    System.assertEquals(true, create.success, create.errorMessage);
    Id sourceId = create.createdRecordIds[0];

    Test.startTest();
    PromoCodeService.LoadedDefinition def = PromoCodeService.loadDefinition(
      sourceId
    );
    Test.stopTest();

    System.assertNotEquals(null, def);
    System.assertEquals('LOADPCT', def.input.code);
    System.assertEquals('Percent', def.input.discountType);
    System.assertEquals(10, def.input.percentValue);
    System.assertEquals('Test terms', def.input.terms);
    System.assertEquals(100, def.input.totalLimit);
    System.assertEquals(5, def.input.perMemberLimit);
    System.assert(def.input.memberTypeScope.contains('Allied'));
    System.assert(def.input.memberTypeScope.contains('Direct'));
    System.assertEquals('Draft', def.currentStatus);
    System.assertEquals(true, def.allDraft);
    System.assert(def.sourceRecordIds.contains(sourceId));
  }

  @IsTest
  static void loadDefinition_amountCode_loadsAllCurrencySiblings() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'LOADAMT';
    inp.discountType = 'Amount';
    inp.percentValue = null;
    inp.percentCurrencies = null;
    // Use the default currency only — multi-currency org behavior is exercised by the
    // sibling-walk logic regardless of how many currencies are present.
    inp.amounts = new List<PromoCodeService.CurrencyAmount>();
    PromoCodeService.CurrencyAmount ca = new PromoCodeService.CurrencyAmount();
    ca.currencyIsoCode = UserInfo.getDefaultCurrency();
    ca.amount = 25;
    inp.amounts.add(ca);
    PromoCodeService.CreateResult create = PromoCodeService.createBulk(inp);
    System.assertEquals(true, create.success, create.errorMessage);
    Id sourceId = create.createdRecordIds[0];

    Test.startTest();
    PromoCodeService.LoadedDefinition def = PromoCodeService.loadDefinition(
      sourceId
    );
    Test.stopTest();

    System.assertEquals('Amount', def.input.discountType);
    System.assertNotEquals(null, def.input.amounts);
    System.assert(
      def.input.amounts.size() >= 1,
      'Expected at least one amount row'
    );
    System.assertEquals(25, def.input.amounts[0].amount);
    System.assertEquals(
      def.sourceRecordIds.size(),
      def.input.amounts.size(),
      'sourceRecordIds and amounts should align 1:1 for Amount codes'
    );
  }

  @IsTest
  static void loadDefinition_nullRecordId_throws() {
    Test.startTest();
    Boolean threw = false;
    try {
      PromoCodeService.loadDefinition(null);
    } catch (Exception e) {
      threw = true;
    }
    Test.stopTest();
    System.assert(threw, 'Expected loadDefinition(null) to throw');
  }

  // ===================================================================================
  // activateBulk
  // ===================================================================================

  @IsTest
  static void activateBulk_flipsDraftToActive() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'ACTBLK';
    PromoCodeService.CreateResult create = PromoCodeService.createBulk(inp);
    System.assertEquals(true, create.success, create.errorMessage);

    Test.startTest();
    PromoCodeService.ActivationResult res = PromoCodeService.activateBulk(
      create.createdRecordIds
    );
    Test.stopTest();

    System.assertEquals(true, res.success);
    System.assertEquals(create.createdRecordIds.size(), res.activatedCount);
    System.assertEquals(0, res.skippedCount);

    for (Promo_Code__c pc : [
      SELECT Id, Status__c
      FROM Promo_Code__c
      WHERE Id IN :create.createdRecordIds
    ]) {
      System.assertEquals('Active', pc.Status__c);
    }
  }

  @IsTest
  static void activateBulk_alreadyActive_isSkipped() {
    PromoCodeService.PromoCodeInput inp = baseInput();
    inp.code = 'ACTBLK_SKIP';
    inp.activateImmediately = true; // create as Active directly
    PromoCodeService.CreateResult create = PromoCodeService.createBulk(inp);
    System.assertEquals(true, create.success, create.errorMessage);

    Test.startTest();
    PromoCodeService.ActivationResult res = PromoCodeService.activateBulk(
      create.createdRecordIds
    );
    Test.stopTest();

    System.assertEquals(
      true,
      res.success,
      'Already-Active records should be a no-op success, not an error'
    );
    System.assertEquals(0, res.activatedCount);
    System.assertEquals(create.createdRecordIds.size(), res.skippedCount);
  }

  @IsTest
  static void activateBulk_emptyInput_returnsErrorMessage() {
    Test.startTest();
    PromoCodeService.ActivationResult resNull = PromoCodeService.activateBulk(
      null
    );
    PromoCodeService.ActivationResult resEmpty = PromoCodeService.activateBulk(
      new List<Id>()
    );
    Test.stopTest();

    System.assertEquals(false, resNull.success);
    System.assertEquals(false, resEmpty.success);
    System.assertNotEquals(null, resNull.errorMessage);
  }
}
