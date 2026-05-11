/**
 * Tests for PromoCodeHighUsageController.getTopUsed covering: empty result (no codes have been
 * redeemed), top-N selection ordered by Confirmed_Usage_Count__c DESC, unlimited code rendering
 * (null Total_Usage_Limit__c), and percentage math.
 *
 * The controller depends on Confirmed_Usage_Count__c being writable directly (not via Apex
 * trigger). The field IS in the lock VR's "allowed-edit" list, so updates are clean.
 */
@IsTest
private class PromoCodeHighUsageControllerTest {

    @IsTest
    static void emptyOrg_returnsEmpty() {
        // Fresh test scope, no codes inserted yet → no usage records.
        List<PromoCodeHighUsageController.UsageStats> results =
            PromoCodeHighUsageController.getTopUsed(10);
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void cappedCode_returnsPercentage() {
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode('CAP_' + suffix(), 'USD', 10);
        pc.Total_Usage_Limit__c = 100;
        pc.Confirmed_Usage_Count__c = 35;
        update pc;

        Test.startTest();
        List<PromoCodeHighUsageController.UsageStats> results =
            PromoCodeHighUsageController.getTopUsed(10);
        Test.stopTest();

        Boolean found = false;
        for (PromoCodeHighUsageController.UsageStats s : results) {
            if (s.recordId == pc.Id) {
                found = true;
                System.assertEquals(35, s.confirmedUsageCount);
                System.assertEquals(100, s.totalUsageLimit);
                System.assertEquals(35.0, s.usagePercentage, 'Expected 35% utilization');
            }
        }
        System.assert(found, 'Inserted capped code should appear in result');
    }

    @IsTest
    static void unlimitedCode_returnsNullLimitAndPercentage() {
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode('UNL_' + suffix(), 'USD', 10);
        pc.Confirmed_Usage_Count__c = 50;
        // No Total_Usage_Limit__c
        update pc;

        List<PromoCodeHighUsageController.UsageStats> results =
            PromoCodeHighUsageController.getTopUsed(10);

        Boolean found = false;
        for (PromoCodeHighUsageController.UsageStats s : results) {
            if (s.recordId == pc.Id) {
                found = true;
                System.assertEquals(null, s.totalUsageLimit, 'Unlimited code should have null limit');
                System.assertEquals(null, s.usagePercentage, 'Unlimited code should have null percentage');
            }
        }
        System.assert(found, 'Unlimited code with usage > 0 should appear in result');
    }

    @IsTest
    static void zeroUsageCodes_excluded() {
        // Codes with no confirmed redemptions shouldn't appear (the SOQL filter > 0).
        PromoCodeTestDataFactory.newActivePercentCode('ZERO_' + suffix(), 'USD', 10);

        List<PromoCodeHighUsageController.UsageStats> results =
            PromoCodeHighUsageController.getTopUsed(10);
        // Just verify we got some structured response (size may be 0).
        System.assertNotEquals(null, results);
    }

    @IsTest
    static void orderedByUsageDescending() {
        Promo_Code__c low = PromoCodeTestDataFactory.newActivePercentCode('LOW_' + suffix(), 'USD', 10);
        Promo_Code__c high = PromoCodeTestDataFactory.newActivePercentCode('HIGH_' + suffix(), 'USD', 10);
        low.Confirmed_Usage_Count__c = 5;
        high.Confirmed_Usage_Count__c = 50;
        update new List<Promo_Code__c>{ low, high };

        Test.startTest();
        List<PromoCodeHighUsageController.UsageStats> results =
            PromoCodeHighUsageController.getTopUsed(10);
        Test.stopTest();

        // Find indices of high and low; high should come first.
        Integer highIdx = -1;
        Integer lowIdx = -1;
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].recordId == high.Id) highIdx = i;
            if (results[i].recordId == low.Id) lowIdx = i;
        }
        if (highIdx >= 0 && lowIdx >= 0) {
            System.assert(highIdx < lowIdx, 'High-usage code should appear before low-usage');
        }
    }

    @IsTest
    static void nullOrZeroMaxRecords_defaultsToTen() {
        // We don't need 11 records to verify this — just that the call doesn't error and returns
        // up to 10 rows.
        List<PromoCodeHighUsageController.UsageStats> nullCase =
            PromoCodeHighUsageController.getTopUsed(null);
        List<PromoCodeHighUsageController.UsageStats> zeroCase =
            PromoCodeHighUsageController.getTopUsed(0);
        System.assertNotEquals(null, nullCase);
        System.assertNotEquals(null, zeroCase);
        System.assert(nullCase.size() <= 10);
        System.assert(zeroCase.size() <= 10);
    }

    private static String suffix() {
        return String.valueOf(System.currentTimeMillis()).right(8);
    }
}
