/**
 * Tests for PromoCodeValidator covering all 9 ordered validation rules from
 * checkout-apply-flow.md §4.4. Each error code gets at least one dedicated test that asserts
 * both errorCode and valid=false; the happy-path test confirms valid=true with no errorCode.
 *
 * To keep tests fast and decoupled from Order/Account DML, an OrderContext is built in-memory.
 * Promo_Code__c records ARE inserted so the validator's parent-record reads are exercised against
 * real org metadata. PCIs are inserted where rules 4 / 5 need pre-existing usage counts.
 *
 * Note: Member_Type_Scope__c is not a validator-level eligibility check in v1 — it's consumed by
 * the allocation engine for product-name CONTAINS matching under Product_Scope_Type__c =
 * 'Specific Membership Types'. See PromoCodeAllocationEngineTest for that coverage.
 */
@IsTest
private class PromoCodeValidatorTest {
  private static final String CURRENCY_ISO = 'USD';

  // -----------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------

  /**
   * @param memberType unused now — kept in the signature so individual tests' call sites still
   *                   read naturally. Member-type scoping in v1 is enforced by matching the
   *                   cart's product names against Member_Type_Scope__c.
   */
  private static PromoCodeApplyService.OrderContext buildContext(
    Id accountId,
    String memberType,
    String region
  ) {
    PromoCodeApplyService.OrderContext ctx = new PromoCodeApplyService.OrderContext();
    ctx.orderId = null;
    ctx.accountId = accountId;
    ctx.currencyIsoCode = CURRENCY_ISO;
    ctx.region = region;
    ctx.orderItems = new List<OrderItem>{
      buildInMemoryLine('Direct Membership', 'Membership', 500, 1)
    };
    return ctx;
  }

  private static OrderItem buildInMemoryLine(
    String productName,
    String family,
    Decimal unitPrice,
    Decimal qty
  ) {
    OrderItem oi = new OrderItem(UnitPrice = unitPrice, Quantity = qty);
    oi.Product2 = new Product2(Name = productName, Family = family);
    return oi;
  }

  private static Account ensureAccount() {
    Account a = new Account(
      Name = 'Validator Test Account ' + System.currentTimeMillis()
    );
    insert a;
    return a;
  }

  private static Promo_Code__c insertActiveCode(String code) {
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      code,
      CURRENCY_ISO,
      'Percent',
      10
    );
    insert pc;
    return pc;
  }

  private static PromoCodeApplyService.UsageCounts emptyUsage() {
    return new PromoCodeApplyService.UsageCounts();
  }

  // -----------------------------------------------------------
  // Validation rule 1: NOT_FOUND
  // -----------------------------------------------------------

  @IsTest
  static void validate_notFound_returnsNotFound() {
    Account a = ensureAccount();
    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'UNKNOWN',
      null,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_NOT_FOUND, cr.errorCode);
    System.assert(cr.errorMessage.contains('UNKNOWN'));
  }

  // -----------------------------------------------------------
  // Rule 2: NOT_ACTIVE
  // -----------------------------------------------------------

  @IsTest
  static void validate_notActive_returnsNotActive() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'DRAFTCODE',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Status__c = 'Draft';
    insert pc;
    // Reload to get fields back
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'DRAFTCODE',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_NOT_ACTIVE, cr.errorCode);
  }

  // -----------------------------------------------------------
  // Rule 3: OUT_OF_WINDOW
  // -----------------------------------------------------------

  @IsTest
  static void validate_outOfWindow_pastEndDate_returnsOutOfWindow() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'PASTEND',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Effective_Start_Date__c = Datetime.now().addDays(-30);
    pc.Effective_End_Date__c = Datetime.now().addDays(-1);
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'PASTEND',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_OUT_OF_WINDOW, cr.errorCode);
  }

  @IsTest
  static void validate_outOfWindow_beforeStartDate_returnsOutOfWindow() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'FUTURESTART',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Effective_Start_Date__c = Datetime.now().addDays(1);
    pc.Effective_End_Date__c = Datetime.now().addDays(30);
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'FUTURESTART',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_OUT_OF_WINDOW, cr.errorCode);
  }

  // -----------------------------------------------------------
  // Rule 4: USAGE_EXCEEDED
  // -----------------------------------------------------------

  @IsTest
  static void validate_usageExceeded_returnsUsageExceeded() {
    // Confirmed_Usage_Count__c is now a Rollup Summary maintained by the platform — Apex can't
    // write it directly. Simulate the "cap reached" state by populating UsageCounts with 5
    // confirmed redemptions (what fetchUsageCounts would return if 5 Confirmed PCIs existed).
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'CAPPED',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Total_Usage_Limit__c = 5;
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.UsageCounts uc = new PromoCodeApplyService.UsageCounts();
    uc.confirmedByCode.put(pc.Id, 5);
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'CAPPED',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      uc
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_USAGE_EXCEEDED, cr.errorCode);
  }

  // -----------------------------------------------------------
  // Rule 5: MEMBER_LIMIT_EXCEEDED
  // -----------------------------------------------------------

  @IsTest
  static void validate_memberLimitExceeded_returnsMemberLimitExceeded() {
    // Populate UsageCounts directly rather than inserting a PCI via Order/OrderItem. The
    // org's Product2 insert Flow blocks new products under test context, and the validator's
    // rule 5 reads usage purely through the UsageCounts container — so we can simulate the
    // "member already at limit" state without any DML on the cart objects.
    Account member = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'PERMEMBERCAP',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Per_Member_Usage_Limit__c = 1;
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.UsageCounts uc = new PromoCodeApplyService.UsageCounts();
    uc.memberPendingByCode.put(pc.Id, 1); // member already at limit

    PromoCodeApplyService.OrderContext ctx = buildContext(
      member.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'PERMEMBERCAP',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      uc
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Rule 6: REGION_INELIGIBLE
  // -----------------------------------------------------------

  @IsTest
  static void validate_regionIneligible_returnsRegionIneligible() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'REGIONED',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Region_Scope__c = 'France;Italy';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'REGIONED',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_REGION_INELIGIBLE,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Rule 7: ACCOUNT_INELIGIBLE
  // -----------------------------------------------------------

  @IsTest
  static void validate_accountIneligible_returnsAccountIneligible() {
    Account sponsor = ensureAccount();
    Account member = new Account(
      Name = 'Other Member ' + System.currentTimeMillis()
    );
    insert member;

    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'SPONSORED',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Account__c = sponsor.Id;
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      member.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'SPONSORED',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Rule 8: NOT_APPLICABLE_TO_CART
  // -----------------------------------------------------------

  @IsTest
  static void validate_notApplicableToCart_returnsNotApplicableToCart() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'SPECIFIC',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Product_Scope_Type__c = 'Specific Products';
    // Specific_Products__c is a CSV of Product2.ProductCode values (per the new contract).
    // The cart's in-memory product has no ProductCode, so no line matches.
    pc.Specific_Products__c = 'EDU-PREMIUM-001';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    // Cart has 'Direct Membership' only.
    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'SPECIFIC',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Rule 8 — extra scope-type coverage of hasEligibleLine branches
  // -----------------------------------------------------------

  @IsTest
  static void validate_productFamily_eligibleLine_passes() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'FAM_OK',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Product_Scope_Type__c = 'Product Family';
    pc.Product_Family_Scope__c = 'Membership';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c,
        Specific_Products__c,
        Application_Level__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    // Cart has a 'Membership'-family line → eligible.
    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'FAM_OK',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(
      true,
      cr.valid,
      'Family-eligible code should validate; got: ' + cr.errorCode
    );
  }

  @IsTest
  static void validate_productFamily_noEligibleLine_returnsNotApplicableToCart() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'FAM_MISS',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Product_Scope_Type__c = 'Product Family';
    pc.Product_Family_Scope__c = 'Chapter;Section';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c,
        Specific_Products__c,
        Application_Level__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'FAM_MISS',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
      cr.errorCode
    );
  }

  @IsTest
  static void validate_specificMembershipTypes_containsMatch_passes() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'SMT_OK',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Product_Scope_Type__c = 'Specific Membership Types';
    // Member_Type_Scope__c is a restricted picklist — values must mirror Membership product
    // names. CONTAINS matching against the cart's 'Direct Membership' line is satisfied here.
    pc.Member_Type_Scope__c = 'Direct Membership';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c,
        Specific_Products__c,
        Application_Level__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    // Cart's 'Direct Membership' line — "Direct" CONTAINS-matches.
    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'SMT_OK',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(
      true,
      cr.valid,
      'Membership-type CONTAINS should match; got: ' + cr.errorCode
    );
  }

  @IsTest
  static void validate_specificMembershipTypes_noContainsMatch_returnsNotApplicableToCart() {
    Account a = ensureAccount();
    Promo_Code__c pc = PromoCodeTestDataFactory.buildBase(
      'SMT_MISS',
      CURRENCY_ISO,
      'Percent',
      10
    );
    pc.Product_Scope_Type__c = 'Specific Membership Types';
    pc.Member_Type_Scope__c = 'Educator Membership;Student Membership';
    insert pc;
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Product_Family_Scope__c,
        Specific_Products__c,
        Application_Level__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    // 'Direct Membership' doesn't contain "Educator" or "Student".
    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'SMT_MISS',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Combinability resolution — runs as a cart-wide post-pass in
  // PromoCodeValidator.resolveCombinability(). Each helper here builds
  // in-memory CodeResult + Promo_Code__c records (no DML) so we can exercise
  // the resolution logic in isolation.
  // -----------------------------------------------------------

  private static PromoCodeApplyService.CodeResult fakeValid(String code) {
    PromoCodeApplyService.CodeResult cr = new PromoCodeApplyService.CodeResult();
    cr.code = code;
    cr.valid = true;
    cr.appliedToOrderItemIds = new List<Id>();
    return cr;
  }

  private static Promo_Code__c fakeParent(
    String code,
    Boolean combinable,
    String groupName
  ) {
    return new Promo_Code__c(
      Code__c = code,
      Combinable__c = combinable,
      Combination_Group__c = groupName,
      Discount_Type__c = 'Percent',
      Discount_Value__c = 10
    );
  }

  @IsTest
  static void resolveCombinability_dropsNonCombinable_whenTwoPlusCombinablesExist() {
    PromoCodeApplyService.CodeResult a = fakeValid('A');
    PromoCodeApplyService.CodeResult b = fakeValid('B');
    PromoCodeApplyService.CodeResult c = fakeValid('C');
    List<PromoCodeApplyService.CodeResult> results = new List<PromoCodeApplyService.CodeResult>{
      a,
      b,
      c
    };
    Map<String, Promo_Code__c> parents = new Map<String, Promo_Code__c>{
      'A' => fakeParent('A', true, 'General'),
      'B' => fakeParent('B', true, 'General'),
      'C' => fakeParent('C', false, null)
    };

    Test.startTest();
    PromoCodeValidator.resolveCombinability(
      results,
      parents,
      buildContext(null, null, 'NA')
    );
    Test.stopTest();

    System.assertEquals(true, a.valid, 'Combinable A should remain valid');
    System.assertEquals(true, b.valid, 'Combinable B should remain valid');
    System.assertEquals(false, c.valid, 'Non-combinable C should be dropped');
    System.assertEquals(
      PromoCodeApplyService.ERR_DROPPED_NON_COMBINABLE,
      c.errorCode
    );
  }

  @IsTest
  static void resolveCombinability_singleCombinablePlusNonCombinable_firstSubmittedWins() {
    PromoCodeApplyService.CodeResult a = fakeValid('A');
    PromoCodeApplyService.CodeResult b = fakeValid('B');
    List<PromoCodeApplyService.CodeResult> results = new List<PromoCodeApplyService.CodeResult>{
      a,
      b
    };
    Map<String, Promo_Code__c> parents = new Map<String, Promo_Code__c>{
      'A' => fakeParent('A', true, 'General'),
      'B' => fakeParent('B', false, null)
    };

    PromoCodeValidator.resolveCombinability(
      results,
      parents,
      buildContext(null, null, 'NA')
    );

    System.assertEquals(true, a.valid, 'First-submitted A wins');
    System.assertEquals(
      false,
      b.valid,
      'B fails NOT_COMBINABLE: only 1 combinable in set, so original exclusive rule applies'
    );
    System.assertEquals(PromoCodeApplyService.ERR_NOT_COMBINABLE, b.errorCode);
  }

  @IsTest
  static void resolveCombinability_groupMismatchAmongCombinables_firstWins() {
    PromoCodeApplyService.CodeResult a = fakeValid('A');
    PromoCodeApplyService.CodeResult b = fakeValid('B');
    List<PromoCodeApplyService.CodeResult> results = new List<PromoCodeApplyService.CodeResult>{
      a,
      b
    };
    Map<String, Promo_Code__c> parents = new Map<String, Promo_Code__c>{
      'A' => fakeParent('A', true, 'Group A'),
      'B' => fakeParent('B', true, 'Group B')
    };

    PromoCodeValidator.resolveCombinability(
      results,
      parents,
      buildContext(null, null, 'NA')
    );

    System.assertEquals(true, a.valid, 'A is the anchor; group Group A');
    System.assertEquals(
      false,
      b.valid,
      'B mismatches anchor group; should fail NOT_COMBINABLE'
    );
    System.assertEquals(PromoCodeApplyService.ERR_NOT_COMBINABLE, b.errorCode);
  }

  @IsTest
  static void resolveCombinability_allSameGroup_allRemainValid() {
    PromoCodeApplyService.CodeResult a = fakeValid('A');
    PromoCodeApplyService.CodeResult b = fakeValid('B');
    PromoCodeApplyService.CodeResult c = fakeValid('C');
    List<PromoCodeApplyService.CodeResult> results = new List<PromoCodeApplyService.CodeResult>{
      a,
      b,
      c
    };
    Map<String, Promo_Code__c> parents = new Map<String, Promo_Code__c>{
      'A' => fakeParent('A', true, 'General'),
      'B' => fakeParent('B', true, 'General'),
      'C' => fakeParent('C', true, 'General')
    };

    PromoCodeValidator.resolveCombinability(
      results,
      parents,
      buildContext(null, null, 'NA')
    );

    System.assertEquals(true, a.valid);
    System.assertEquals(true, b.valid);
    System.assertEquals(true, c.valid);
  }

  @IsTest
  static void resolveCombinability_twoNonCombinables_firstWins() {
    PromoCodeApplyService.CodeResult a = fakeValid('A');
    PromoCodeApplyService.CodeResult b = fakeValid('B');
    List<PromoCodeApplyService.CodeResult> results = new List<PromoCodeApplyService.CodeResult>{
      a,
      b
    };
    Map<String, Promo_Code__c> parents = new Map<String, Promo_Code__c>{
      'A' => fakeParent('A', false, null),
      'B' => fakeParent('B', false, null)
    };

    PromoCodeValidator.resolveCombinability(
      results,
      parents,
      buildContext(null, null, 'NA')
    );

    System.assertEquals(true, a.valid, 'First non-combinable wins');
    System.assertEquals(false, b.valid, 'Second non-combinable fails');
    System.assertEquals(PromoCodeApplyService.ERR_NOT_COMBINABLE, b.errorCode);
  }

  // -----------------------------------------------------------
  // Happy path
  // -----------------------------------------------------------

  @IsTest
  static void validate_allChecksPass_returnsValid() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('HAPPY');
    pc = [
      SELECT
        Id,
        Code__c,
        Status__c,
        Display_Name__c,
        Effective_Start_Date__c,
        Effective_End_Date__c,
        Total_Usage_Limit__c,
        Per_Member_Usage_Limit__c,
        Member_Type_Scope__c,
        Region_Scope__c,
        Account__c,
        Product_Scope_Type__c,
        Specific_Products__c,
        Combinable__c,
        Combination_Group__c,
        Discount_Type__c,
        Discount_Value__c,
        Applicable_To__c,
        Min_Months_Since_Last_Active__c
      FROM Promo_Code__c
      WHERE Id = :pc.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'HAPPY',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(
      true,
      cr.valid,
      'Expected happy path. Got: ' + cr.errorCode + '/' + cr.errorMessage
    );
    System.assertEquals(null, cr.errorCode);
  }

  // -----------------------------------------------------------
  // fetchUsageCounts smoke test
  // -----------------------------------------------------------

  @IsTest
  static void fetchUsageCounts_emptySet_returnsEmpty() {
    PromoCodeApplyService.UsageCounts uc = PromoCodeValidator.fetchUsageCounts(
      new Set<Id>(),
      null
    );
    System.assertEquals(0, uc.pendingByCode.size());
    System.assertEquals(0, uc.confirmedByCode.size());
  }

  @IsTest
  static void messageFor_returnsExpectedTextForEachErrorCode() {
    Account a = ensureAccount();
    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );

    // Exercise every messageFor branch for coverage + safety
    for (
      String code : new List<String>{
        PromoCodeApplyService.ERR_NOT_FOUND,
        PromoCodeApplyService.ERR_NOT_ACTIVE,
        PromoCodeApplyService.ERR_OUT_OF_WINDOW,
        PromoCodeApplyService.ERR_USAGE_EXCEEDED,
        PromoCodeApplyService.ERR_MEMBER_LIMIT_EXCEEDED,
        PromoCodeApplyService.ERR_REGION_INELIGIBLE,
        PromoCodeApplyService.ERR_ACCOUNT_INELIGIBLE,
        PromoCodeApplyService.ERR_NOT_APPLICABLE_TO_CART,
        PromoCodeApplyService.ERR_NOT_COMBINABLE,
        PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
        PromoCodeApplyService.ERR_MEMBER_RECENTLY_ACTIVE,
        PromoCodeApplyService.ERR_DROPPED_NON_COMBINABLE,
        'UNKNOWN_CODE'
      }
    ) {
      String msg = PromoCodeValidator.messageFor(code, null, ctx, 'TESTCODE');
      System.assertNotEquals(null, msg, 'messageFor returned null for ' + code);
    }
  }

  // -----------------------------------------------------------
  // Validation rule 7a: FLOW_NOT_APPLICABLE
  // -----------------------------------------------------------

  @IsTest
  static void validate_renewFlow_joinOnlyCode_returnsFlowNotApplicable() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('JOINONLY');
    pc.Applicable_To__c = 'Join';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_RENEW;

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'JOINONLY',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
      cr.errorCode
    );
  }

  @IsTest
  static void validate_joinFlow_renewOnlyCode_returnsFlowNotApplicable() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('RENEWONLY');
    pc.Applicable_To__c = 'Renew';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_JOIN;

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'RENEWONLY',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
      cr.errorCode
    );
  }

  @IsTest
  static void validate_bothCode_matchesEitherFlow() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('BOTHCODE');
    // Applicable_To defaults to 'Both' via the picklist default.

    PromoCodeApplyService.OrderContext joinCtx = buildContext(a.Id, null, 'NA');
    joinCtx.flowType = PromoCodeApplyService.FLOW_JOIN;
    PromoCodeApplyService.CodeResult joinResult = PromoCodeValidator.validate(
      'BOTHCODE',
      pc,
      joinCtx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );
    System.assertEquals(
      true,
      joinResult.valid,
      'err=' + joinResult.errorMessage
    );

    PromoCodeApplyService.OrderContext renewCtx = buildContext(
      a.Id,
      null,
      'NA'
    );
    renewCtx.flowType = PromoCodeApplyService.FLOW_RENEW;
    PromoCodeApplyService.CodeResult renewResult = PromoCodeValidator.validate(
      'BOTHCODE',
      pc,
      renewCtx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );
    System.assertEquals(
      true,
      renewResult.valid,
      'err=' + renewResult.errorMessage
    );
  }

  @IsTest
  static void validate_blankFlowType_treatedAsJoin() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('JOINBLANK');
    pc.Applicable_To__c = 'Renew';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = null; // null -> default Join inside validator

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'JOINBLANK',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_FLOW_NOT_APPLICABLE,
      cr.errorCode
    );
  }

  // -----------------------------------------------------------
  // Validation rule 7b: MEMBER_RECENTLY_ACTIVE
  // -----------------------------------------------------------

  @IsTest
  static void validate_join_lookback_recentMember_returnsRecentlyActive() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('LAPSED12');
    pc.Min_Months_Since_Last_Active__c = 12;
    pc.Applicable_To__c = 'Join';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_JOIN;
    ctx.lastActiveMembershipDate = Date.today().addMonths(-3); // 3 months ago

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'LAPSED12',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(
      PromoCodeApplyService.ERR_MEMBER_RECENTLY_ACTIVE,
      cr.errorCode
    );
  }

  @IsTest
  static void validate_join_lookback_lapsedMember_passes() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('LAPSED12OK');
    pc.Min_Months_Since_Last_Active__c = 12;
    pc.Applicable_To__c = 'Join';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_JOIN;
    ctx.lastActiveMembershipDate = Date.today().addMonths(-18); // 18 months ago

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'LAPSED12OK',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(true, cr.valid, 'err=' + cr.errorMessage);
  }

  @IsTest
  static void validate_join_lookback_neverActiveMember_passes() {
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('NEVERACTIVE');
    pc.Min_Months_Since_Last_Active__c = 12;
    pc.Applicable_To__c = 'Join';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_JOIN;
    ctx.lastActiveMembershipDate = null; // no prior membership on file

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'NEVERACTIVE',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(
      true,
      cr.valid,
      'null Last_Active should be treated as never-active and pass'
    );
  }

  @IsTest
  static void validate_renewFlow_lookbackIgnored() {
    // Min Months only applies to Join. A Renew cart should never hit this check even
    // if the code's lookback is set (and a Both code is the only way the renew cart
    // would survive the FLOW_NOT_APPLICABLE rule when Min Months is set).
    Account a = ensureAccount();
    Promo_Code__c pc = insertActiveCode('BOTHLAPSE');
    pc.Min_Months_Since_Last_Active__c = 12;
    pc.Applicable_To__c = 'Both';
    update pc;

    PromoCodeApplyService.OrderContext ctx = buildContext(a.Id, null, 'NA');
    ctx.flowType = PromoCodeApplyService.FLOW_RENEW;
    ctx.lastActiveMembershipDate = Date.today().addMonths(-2); // very recent

    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'BOTHLAPSE',
      pc,
      ctx,
      new List<Promo_Code__c>(),
      emptyUsage()
    );

    System.assertEquals(
      true,
      cr.valid,
      'Lookback should be skipped for Renew carts: ' + cr.errorMessage
    );
  }
}
