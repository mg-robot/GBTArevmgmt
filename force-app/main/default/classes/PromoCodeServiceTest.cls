@IsTest
private class PromoCodeServiceTest {

    private static PromoCodeService.PromoCodeInput baseInput() {
        PromoCodeService.PromoCodeInput in = new PromoCodeService.PromoCodeInput();
        in.code = 'TESTCODE';
        in.displayName = 'Test Code';
        in.discountType = 'Percent';
        in.percentValue = 10;
        in.percentCurrencies = new List<String>{ UserInfo.getDefaultCurrency() };
        in.effectiveStart = Datetime.now();
        in.effectiveEnd = Datetime.now().addDays(30);
        in.combinable = true;
        in.combinationGroup = 'General';
        in.productScopeType = 'All Items';
        in.approvalRequired = false;
        return in;
    }

    @IsTest
    static void getActiveCurrencies_returnsAtLeastOne() {
        Test.startTest();
        List<String> currencies = PromoCodeService.getActiveCurrencies();
        Test.stopTest();
        System.assert(!currencies.isEmpty(), 'Expected at least one active currency');
    }

    @IsTest
    static void searchProducts_returnsMatchingActiveProducts() {
        Product2 p = new Product2(Name = 'Widget Promo Test', ProductCode = 'WPT-1', IsActive = true);
        insert p;

        Test.startTest();
        List<PromoCodeService.ProductOption> hits = PromoCodeService.searchProducts('Widget');
        Test.stopTest();

        System.assertEquals(1, hits.size());
        System.assertEquals('Widget Promo Test', hits[0].name);
        System.assertEquals('WPT-1', hits[0].productCode);
    }

    @IsTest
    static void searchProducts_shortTermReturnsEmpty() {
        List<PromoCodeService.ProductOption> hits = PromoCodeService.searchProducts('a');
        System.assert(hits.isEmpty(), 'Sub-2-char terms should return no hits');
    }

    @IsTest
    static void checkCodeUniqueness_noConflictReturnsEmpty() {
        List<String> conflicts = PromoCodeService.checkCodeUniqueness('NEVERUSED');
        System.assert(conflicts.isEmpty());
    }

    @IsTest
    static void createBulk_percentSuccess() {
        Test.startTest();
        PromoCodeService.CreateResult r = PromoCodeService.createBulk(baseInput());
        Test.stopTest();

        System.assertEquals(true, r.success, r.errorMessage);
        System.assertEquals(1, r.createdRecordIds.size());
        Promo_Code__c saved = [SELECT Code__c, Discount_Type__c, Discount_Value__c, Status__c
                               FROM Promo_Code__c WHERE Id = :r.createdRecordIds[0]];
        System.assertEquals('TESTCODE', saved.Code__c);
        System.assertEquals('Percent', saved.Discount_Type__c);
        System.assertEquals(10, saved.Discount_Value__c);
        System.assertEquals('Draft', saved.Status__c);
    }

    @IsTest
    static void createBulk_amountSuccess() {
        PromoCodeService.PromoCodeInput in = baseInput();
        in.code = 'AMOUNTCODE';
        in.discountType = 'Amount';
        in.percentValue = null;
        in.percentCurrencies = null;
        PromoCodeService.CurrencyAmount ca = new PromoCodeService.CurrencyAmount();
        ca.currencyIsoCode = UserInfo.getDefaultCurrency();
        ca.amount = 25;
        in.amounts = new List<PromoCodeService.CurrencyAmount>{ ca };

        Test.startTest();
        PromoCodeService.CreateResult r = PromoCodeService.createBulk(in);
        Test.stopTest();

        System.assertEquals(true, r.success, r.errorMessage);
        System.assertEquals(1, r.createdRecordIds.size());
        Promo_Code__c saved = [SELECT Discount_Type__c, Discount_Value__c
                               FROM Promo_Code__c WHERE Id = :r.createdRecordIds[0]];
        System.assertEquals('Amount', saved.Discount_Type__c);
        System.assertEquals(25, saved.Discount_Value__c);
    }

    @IsTest
    static void createBulk_invalidPercentRejected() {
        PromoCodeService.PromoCodeInput in = baseInput();
        in.percentValue = 150;

        PromoCodeService.CreateResult r = PromoCodeService.createBulk(in);
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('between 0 and 100'));
    }

    @IsTest
    static void createBulk_amountWithoutAmountsRejected() {
        PromoCodeService.PromoCodeInput in = baseInput();
        in.discountType = 'Amount';
        in.amounts = null;

        PromoCodeService.CreateResult r = PromoCodeService.createBulk(in);
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('currency-amount'));
    }

    @IsTest
    static void createBulk_missingRequiredFieldsRejected() {
        PromoCodeService.PromoCodeInput in = new PromoCodeService.PromoCodeInput();
        PromoCodeService.CreateResult r = PromoCodeService.createBulk(in);
        System.assertEquals(false, r.success);
        System.assert(r.errorMessage.contains('Missing required'));
    }

    @IsTest
    static void createBulk_duplicateCodeBlocked() {
        Boolean isMC = Schema.getGlobalDescribe().containsKey('CurrencyType')
            && Schema.SObjectType.Promo_Code__c.fields.getMap().containsKey('currencyisocode');
        if (!isMC) {
            return; // skip in single-currency orgs (composite uniqueness only meaningful in MC)
        }
        PromoCodeService.createBulk(baseInput());

        Test.startTest();
        PromoCodeService.CreateResult r = PromoCodeService.createBulk(baseInput());
        Test.stopTest();

        System.assertEquals(false, r.success);
        System.assertNotEquals(null, r.conflictCurrencies);
        System.assert(!r.conflictCurrencies.isEmpty());
    }
}
