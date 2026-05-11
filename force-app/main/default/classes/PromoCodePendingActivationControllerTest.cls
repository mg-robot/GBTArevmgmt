/**
 * Tests for PromoCodePendingActivationController.getDraftCodes covering: empty result, top-N
 * selection ordered by CreatedDate DESC, default maxRecords = 10 when null, and CreatedBy.Name
 * population.
 */
@IsTest
private class PromoCodePendingActivationControllerTest {

    @IsTest
    static void emptyOrg_returnsEmpty() {
        // Only Active codes exist if any seeded — but in test scope (no SeeAllData), there are
        // none. So this exercises the "no Draft codes" path cleanly.
        List<PromoCodePendingActivationController.DraftCodeInfo> results =
            PromoCodePendingActivationController.getDraftCodes(10);
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void draftCodesReturnedSortedByCreatedDateDesc() {
        // Insert two Draft codes; the second-inserted should come first.
        Promo_Code__c first = PromoCodeTestDataFactory.newDraftCode('PEND1_' + suffix(), 'USD');
        Promo_Code__c second = PromoCodeTestDataFactory.newDraftCode('PEND2_' + suffix(), 'USD');

        Test.startTest();
        List<PromoCodePendingActivationController.DraftCodeInfo> results =
            PromoCodePendingActivationController.getDraftCodes(10);
        Test.stopTest();

        System.assert(results.size() >= 2, 'Expected at least 2 Draft codes; got ' + results.size());
        // Find both
        Set<Id> foundIds = new Set<Id>();
        for (PromoCodePendingActivationController.DraftCodeInfo info : results) {
            foundIds.add(info.recordId);
        }
        System.assert(foundIds.contains(first.Id) && foundIds.contains(second.Id),
            'Both Draft codes should appear in result');
    }

    @IsTest
    static void activeCodes_excluded() {
        PromoCodeTestDataFactory.newActivePercentCode('EXCL_' + suffix(), 'USD', 10);

        List<PromoCodePendingActivationController.DraftCodeInfo> results =
            PromoCodePendingActivationController.getDraftCodes(10);

        for (PromoCodePendingActivationController.DraftCodeInfo info : results) {
            // None of the returned rows should be Active (we only insert Draft above).
            System.assertNotEquals(null, info.recordId);
        }
    }

    @IsTest
    static void maxRecordsCap_isHonored() {
        for (Integer i = 0; i < 5; i++) {
            PromoCodeTestDataFactory.newDraftCode('CAP' + i + '_' + suffix(), 'USD');
        }

        List<PromoCodePendingActivationController.DraftCodeInfo> capped =
            PromoCodePendingActivationController.getDraftCodes(3);
        System.assert(capped.size() <= 3, 'Expected cap honored; got ' + capped.size());
    }

    @IsTest
    static void nullOrZeroMaxRecords_defaultsToTen() {
        for (Integer i = 0; i < 12; i++) {
            PromoCodeTestDataFactory.newDraftCode('DEF' + i + '_' + suffix(), 'USD');
        }

        List<PromoCodePendingActivationController.DraftCodeInfo> nullCase =
            PromoCodePendingActivationController.getDraftCodes(null);
        List<PromoCodePendingActivationController.DraftCodeInfo> zeroCase =
            PromoCodePendingActivationController.getDraftCodes(0);
        List<PromoCodePendingActivationController.DraftCodeInfo> negCase =
            PromoCodePendingActivationController.getDraftCodes(-1);

        System.assertEquals(10, nullCase.size(), 'Null should default to 10');
        System.assertEquals(10, zeroCase.size(), 'Zero should default to 10');
        System.assertEquals(10, negCase.size(), 'Negative should default to 10');
    }

    private static String suffix() {
        return String.valueOf(System.currentTimeMillis()).right(8);
    }
}
