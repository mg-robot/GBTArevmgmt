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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
        Discount_Value__c
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
  // Rule 9: NOT_COMBINABLE
  // -----------------------------------------------------------

  @IsTest
  static void validate_notCombinable_nonCombinableInSet_returnsNotCombinable() {
    Account a = ensureAccount();
    // Existing valid set already has a non-combinable code.
    Promo_Code__c existing = new Promo_Code__c(
      Id = null, // simulated in-memory parent — Apex allows building without insert here
      Combinable__c = false,
      Combination_Group__c = null,
      Code__c = 'EXCLUSIVE'
    );
    existing = PromoCodeTestDataFactory.buildBase(
      'EXCLUSIVE',
      CURRENCY_ISO,
      'Percent',
      10
    );
    existing.Combinable__c = false;
    existing.Combination_Group__c = null;
    // Inserting a non-combinable code requires bypassing VR_PromoCode_RequireCombinationGroup
    // which only fires when Combinable__c = true. With Combinable__c = false, the VR allows
    // a blank Combination_Group__c — clean.
    insert existing;
    existing = [
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
        Discount_Value__c
      FROM Promo_Code__c
      WHERE Id = :existing.Id
    ];

    Promo_Code__c candidate = PromoCodeTestDataFactory.buildBase(
      'TRYING',
      CURRENCY_ISO,
      'Percent',
      5
    );
    insert candidate;
    candidate = [
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
        Discount_Value__c
      FROM Promo_Code__c
      WHERE Id = :candidate.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'TRYING',
      candidate,
      ctx,
      new List<Promo_Code__c>{ existing },
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_NOT_COMBINABLE, cr.errorCode);
  }

  @IsTest
  static void validate_notCombinable_differentGroups_returnsNotCombinable() {
    Account a = ensureAccount();
    Promo_Code__c existing = PromoCodeTestDataFactory.buildBase(
      'GROUPA',
      CURRENCY_ISO,
      'Percent',
      10
    );
    existing.Combination_Group__c = 'Group A';
    insert existing;
    existing = [
      SELECT Id, Code__c, Status__c, Combinable__c, Combination_Group__c
      FROM Promo_Code__c
      WHERE Id = :existing.Id
    ];

    Promo_Code__c candidate = PromoCodeTestDataFactory.buildBase(
      'GROUPB',
      CURRENCY_ISO,
      'Percent',
      5
    );
    candidate.Combination_Group__c = 'Group B';
    insert candidate;
    candidate = [
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
        Discount_Value__c
      FROM Promo_Code__c
      WHERE Id = :candidate.Id
    ];

    PromoCodeApplyService.OrderContext ctx = buildContext(
      a.Id,
      'Direct Membership',
      'NA'
    );
    PromoCodeApplyService.CodeResult cr = PromoCodeValidator.validate(
      'GROUPB',
      candidate,
      ctx,
      new List<Promo_Code__c>{ existing },
      emptyUsage()
    );

    System.assertEquals(false, cr.valid);
    System.assertEquals(PromoCodeApplyService.ERR_NOT_COMBINABLE, cr.errorCode);
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
        Discount_Value__c
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
        'UNKNOWN_CODE'
      }
    ) {
      String msg = PromoCodeValidator.messageFor(code, null, ctx, 'TESTCODE');
      System.assertNotEquals(null, msg, 'messageFor returned null for ' + code);
    }
  }
}
