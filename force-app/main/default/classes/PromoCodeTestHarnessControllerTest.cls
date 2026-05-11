/**
 * Tests for PromoCodeTestHarnessController. The controller is a thin wrapper around existing
 * services + a delete pattern; tests focus on null-input guards, happy-path return shapes, and
 * idempotency.
 *
 * Uses PromoCodeTestDataFactory for fixture creation. SeeAllData=true because the factory's
 * "use existing Membership products" path is the reliable way to get OrderItems in this org.
 */
@IsTest(SeeAllData=true)
private class PromoCodeTestHarnessControllerTest {

    private static final String CURRENCY_ISO = 'USD';

    private static Order setupOrder() {
        Account member = PromoCodeTestDataFactory.newMember();
        Order ord = PromoCodeTestDataFactory.newOrder(member, CURRENCY_ISO, null, null);
        List<OrderItem> ois = PromoCodeTestDataFactory.addItemsFromExistingMembershipProducts(ord, 1);
        if (ois.isEmpty()) return null;
        return ord;
    }

    @IsTest
    static void triggerReprice_nullOrderId_throws() {
        try {
            PromoCodeTestHarnessController.triggerReprice(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void triggerReprice_returnsJsonSnapshot() {
        Order ord = setupOrder();
        if (ord == null) return;

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(
            'HARNESS_' + String.valueOf(System.currentTimeMillis()).right(8), CURRENCY_ISO, 10
        );
        PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        Test.startTest();
        String json = PromoCodeTestHarnessController.triggerReprice(ord.Id);
        Test.stopTest();

        System.assertNotEquals(null, json);
        System.assert(json.contains('Promo_Code_Item__c') || json.contains(pc.Id),
            'Snapshot should reference the inserted PCI or its type');
    }

    @IsTest
    static void simulatePrePlaceValidation_returnsCodeResults() {
        Order ord = setupOrder();
        if (ord == null) return;

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(
            'PREPLACE_' + String.valueOf(System.currentTimeMillis()).right(8), CURRENCY_ISO, 10
        );
        PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        Test.startTest();
        List<PromoCodeApplyService.CodeResult> results =
            PromoCodeTestHarnessController.simulatePrePlaceValidation(ord.Id);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].valid);
    }

    @IsTest
    static void resetTestData_deletesPcisAndClearsCsv() {
        Order ord = setupOrder();
        if (ord == null) return;

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(
            'RESET_' + String.valueOf(System.currentTimeMillis()).right(8), CURRENCY_ISO, 10
        );
        PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        Test.startTest();
        String result = PromoCodeTestHarnessController.resetTestData(ord.Id);
        Test.stopTest();

        System.assert(result.contains('Deleted'), 'Result message should describe the deletion');

        Integer remaining = [SELECT COUNT() FROM Promo_Code_Item__c WHERE Order_Item__r.OrderId = :ord.Id];
        System.assertEquals(0, remaining, 'All PCIs should be deleted');

        Order reloaded = [SELECT Promo_Codes_Entered__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals(null, reloaded.Promo_Codes_Entered__c);
    }

    @IsTest
    static void resetTestData_nullOrderId_throws() {
        try {
            PromoCodeTestHarnessController.resetTestData(null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void resetTestData_emptyOrder_noOp() {
        Order ord = setupOrder();
        if (ord == null) return;

        Test.startTest();
        String result = PromoCodeTestHarnessController.resetTestData(ord.Id);
        Test.stopTest();

        System.assert(result.contains('Deleted 0'), 'Empty order should report 0 deletions');
    }
}
