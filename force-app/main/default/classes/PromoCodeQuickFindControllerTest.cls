/**
 * Tests for PromoCodeQuickFindController.findByCode covering: blank input, single match,
 * multi-currency multi-match, and no-match. Re-uses PromoCodeTestDataFactory for fixture creation.
 */
@IsTest
private class PromoCodeQuickFindControllerTest {

    @IsTest
    static void blankInput_returnsEmpty() {
        System.assertEquals(0, PromoCodeQuickFindController.findByCode(null).size());
        System.assertEquals(0, PromoCodeQuickFindController.findByCode('').size());
        System.assertEquals(0, PromoCodeQuickFindController.findByCode('   ').size());
    }

    @IsTest
    static void singleMatch_returnsOneResult() {
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode('QFTEST_' + suffix(), 'USD', 10);

        Test.startTest();
        List<PromoCodeQuickFindController.MatchResult> results =
            PromoCodeQuickFindController.findByCode(pc.Code__c);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(pc.Id, results[0].recordId);
        System.assertEquals(pc.Code__c, results[0].code);
        System.assertEquals('Active', results[0].status);
    }

    @IsTest
    static void caseInsensitiveAndWhitespaceTolerant() {
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode('CASETEST' + suffix(), 'USD', 10);

        // Lower-case + padding should still match (controller upper-cases and trims).
        List<PromoCodeQuickFindController.MatchResult> results =
            PromoCodeQuickFindController.findByCode('  ' + pc.Code__c.toLowerCase() + '  ');

        System.assertEquals(1, results.size());
    }

    @IsTest
    static void multiCurrency_multiMatch_returnsAll() {
        Boolean isMC = Schema.SObjectType.Promo_Code__c.fields.getMap().containsKey('currencyisocode');
        if (!isMC) return; // single-currency orgs can't exercise this path

        List<String> isos = PromoCodeService.getActiveCurrencies();
        if (isos.size() < 2) return;

        String code = 'MULTI_' + suffix();
        for (Integer i = 0; i < Math.min(isos.size(), 3); i++) {
            PromoCodeTestDataFactory.newActivePercentCode(code, isos[i], 10);
        }

        Test.startTest();
        List<PromoCodeQuickFindController.MatchResult> results =
            PromoCodeQuickFindController.findByCode(code);
        Test.stopTest();

        System.assert(results.size() >= 2, 'Expected multi-currency matches; got ' + results.size());
        // Currency labels should be set.
        for (PromoCodeQuickFindController.MatchResult r : results) {
            System.assertNotEquals(null, r.currencyIsoCode, 'currencyIsoCode missing on result');
        }
    }

    @IsTest
    static void noMatch_returnsEmpty() {
        List<PromoCodeQuickFindController.MatchResult> results =
            PromoCodeQuickFindController.findByCode('NEVERUSED_' + suffix());
        System.assertEquals(0, results.size());
    }

    private static String suffix() {
        return String.valueOf(System.currentTimeMillis()).right(8);
    }
}
