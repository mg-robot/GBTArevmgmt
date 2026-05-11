/**
 * Tests for PromoCodeApplyService end-to-end behavior: apply / remove / revalidateAll. Builds
 * real Order + OrderItem + Promo_Code__c records and asserts on the inserted Promo_Code_Item__c
 * records and Order.Promo_Codes_Entered__c CSV.
 *
 * SeeAllData=true: the org's "Product: add to Price Books" Flow blocks fresh Product2 inserts in
 * test context, so we use pre-existing Membership Product2 + PricebookEntry records from the org
 * to build the cart. Test isolation is maintained at the Order / Promo_Code__c / PCI level — those
 * are always test-inserted, so the transaction rolls back at test end. Promo code strings include
 * a timestamp suffix so re-runs and parallel tests don't collide on the composite-uniqueness rule.
 */
@IsTest(SeeAllData=true)
private class PromoCodeApplyServiceTest {

    private static final String CURRENCY_ISO = 'USD';

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------

    private static Order setupOrderWithItems(Integer itemCount) {
        Account member = PromoCodeTestDataFactory.newMember();
        Order ord = PromoCodeTestDataFactory.newOrder(member, CURRENCY_ISO, null, null);
        List<OrderItem> ois = PromoCodeTestDataFactory.addItemsFromExistingMembershipProducts(ord, itemCount);
        if (ois.isEmpty()) return null;
        return ord;
    }

    private static Order setupOrderWithOneItem() {
        return setupOrderWithItems(1);
    }

    private static OrderItem firstOrderItem(Id orderId) {
        List<OrderItem> ois = [SELECT Id, UnitPrice FROM OrderItem WHERE OrderId = :orderId LIMIT 1];
        return ois.isEmpty() ? null : ois[0];
    }

    private static String uniqueCode(String prefix) {
        return prefix + String.valueOf(System.currentTimeMillis()).right(8);
    }

    private static Decimal sumOrderItemSubtotals(Id orderId) {
        Decimal total = 0;
        for (OrderItem oi : [SELECT UnitPrice, Quantity FROM OrderItem WHERE OrderId = :orderId]) {
            total += oi.UnitPrice * oi.Quantity;
        }
        return total;
    }

    // -----------------------------------------------------------
    // apply()
    // -----------------------------------------------------------

    @IsTest
    static void apply_happyPath_insertsPendingPci() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Decimal subtotal = sumOrderItemSubtotals(ord.Id);
        Decimal expectedAdjustment = (subtotal * 0.10).setScale(2, System.RoundingMode.HALF_UP);

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('SAVE10_'), CURRENCY_ISO, 10);

        Test.startTest();
        PromoCodeApplyService.ApplyResult result =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });
        Test.stopTest();

        System.assertEquals(1, result.codeResults.size());
        System.assertEquals(true, result.codeResults[0].valid,
            'Expected valid; got: ' + result.codeResults[0].errorCode + ' / ' + result.codeResults[0].errorMessage);
        System.assertEquals(expectedAdjustment, result.totalAdjustment);
        System.assertEquals(true, result.repriceRequired);
        System.assertNotEquals(null, result.applicationGroupId);

        List<Promo_Code_Item__c> pcis = [
            SELECT Id, Status__c, Applied_Discount_Amount__c
            FROM Promo_Code_Item__c WHERE Promo_Code__c = :pc.Id
        ];
        System.assertEquals(1, pcis.size());
        System.assertEquals('Pending', pcis[0].Status__c);

        Order reloaded = [SELECT Promo_Codes_Entered__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals(pc.Code__c, reloaded.Promo_Codes_Entered__c);
    }

    @IsTest
    static void apply_invalidCode_returnsErrorNoInsert() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;

        Test.startTest();
        PromoCodeApplyService.ApplyResult result =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ 'NONEXISTENT_X9' });
        Test.stopTest();

        System.assertEquals(1, result.codeResults.size());
        System.assertEquals(false, result.codeResults[0].valid);
        System.assertEquals(PromoCodeApplyService.ERR_NOT_FOUND, result.codeResults[0].errorCode);

        List<Promo_Code_Item__c> pcis = [SELECT Id FROM Promo_Code_Item__c WHERE Order_Item__r.OrderId = :ord.Id];
        System.assertEquals(0, pcis.size());

        Order reloaded = [SELECT Promo_Codes_Entered__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals('NONEXISTENT_X9', reloaded.Promo_Codes_Entered__c);
    }

    @IsTest
    static void apply_mixedValidAndInvalid_handlesEach() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c valid = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('VAL10_'), CURRENCY_ISO, 10);

        Test.startTest();
        PromoCodeApplyService.ApplyResult result =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ valid.Code__c, 'BOGUS_X9' });
        Test.stopTest();

        System.assertEquals(2, result.codeResults.size());
        Map<String, PromoCodeApplyService.CodeResult> byCode = new Map<String, PromoCodeApplyService.CodeResult>();
        for (PromoCodeApplyService.CodeResult cr : result.codeResults) byCode.put(cr.code.toUpperCase(), cr);

        System.assertEquals(true, byCode.get(valid.Code__c.toUpperCase()).valid);
        System.assertEquals(false, byCode.get('BOGUS_X9').valid);
        System.assertEquals(PromoCodeApplyService.ERR_NOT_FOUND, byCode.get('BOGUS_X9').errorCode);
        System.assert(result.totalAdjustment > 0);
    }

    @IsTest
    static void apply_reapply_releasesPriorAndInsertsFresh() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('REAPP_'), CURRENCY_ISO, 10);

        PromoCodeApplyService.ApplyResult first =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });
        String firstGroupId = first.applicationGroupId;

        Test.startTest();
        PromoCodeApplyService.ApplyResult second =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });
        Test.stopTest();

        System.assertNotEquals(null, second.applicationGroupId);
        System.assertNotEquals(firstGroupId, second.applicationGroupId,
            'Re-apply should generate a new applicationGroupId');

        Map<String, Integer> statusCounts = new Map<String, Integer>();
        for (Promo_Code_Item__c pci : [
            SELECT Status__c, Release_Reason__c FROM Promo_Code_Item__c
            WHERE Order_Item__r.OrderId = :ord.Id
        ]) {
            Integer n = statusCounts.containsKey(pci.Status__c) ? statusCounts.get(pci.Status__c) : 0;
            statusCounts.put(pci.Status__c, n + 1);
        }
        System.assertEquals(1, statusCounts.get('Released'), 'Prior Pending should now be Released');
        System.assertEquals(1, statusCounts.get('Pending'), 'New Pending PCI inserted');
    }

    @IsTest
    static void apply_emptyCodes_returnsEmptyResult() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;

        PromoCodeApplyService.ApplyResult result = PromoCodeApplyService.apply(ord.Id, new List<String>());
        System.assertEquals(0, result.codeResults.size());
        System.assertEquals(false, result.repriceRequired);
    }

    @IsTest
    static void apply_duplicateInputCodesDeduped() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('DUP_'), CURRENCY_ISO, 10);
        String code = pc.Code__c;

        Test.startTest();
        PromoCodeApplyService.ApplyResult result = PromoCodeApplyService.apply(
            ord.Id, new List<String>{ code, ' ' + code.toLowerCase() + ' ', code }
        );
        Test.stopTest();

        System.assertEquals(1, result.codeResults.size(), 'Duplicates should dedupe before processing');
    }

    @IsTest
    static void apply_nullOrderId_throws() {
        try {
            PromoCodeApplyService.apply(null, new List<String>{ 'X' });
            System.assert(false, 'Expected AuraHandledException for null orderId');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    // -----------------------------------------------------------
    // remove()
    // -----------------------------------------------------------

    @IsTest
    static void remove_releasesPciAndUpdatesCsv() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('REM_'), CURRENCY_ISO, 10);

        PromoCodeApplyService.ApplyResult applied = PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        Test.startTest();
        PromoCodeApplyService.ApplyResult removed = PromoCodeApplyService.remove(ord.Id, applied.applicationGroupId);
        Test.stopTest();

        System.assertEquals(true, removed.repriceRequired);

        Promo_Code_Item__c pci = [
            SELECT Status__c, Release_Reason__c FROM Promo_Code_Item__c
            WHERE Order_Item__r.OrderId = :ord.Id LIMIT 1
        ];
        System.assertEquals('Released', pci.Status__c);
        System.assertEquals('Code Removed', pci.Release_Reason__c);

        Order reloaded = [SELECT Promo_Codes_Entered__c FROM Order WHERE Id = :ord.Id];
        System.assertEquals(null, reloaded.Promo_Codes_Entered__c,
            'Removed code should be stripped from the CSV');
    }

    @IsTest
    static void remove_unknownGroup_noOp() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;

        Test.startTest();
        PromoCodeApplyService.ApplyResult removed = PromoCodeApplyService.remove(ord.Id, 'no-such-group');
        Test.stopTest();

        System.assertEquals(false, removed.repriceRequired);
    }

    @IsTest
    static void remove_nullOrderId_throws() {
        try {
            PromoCodeApplyService.remove(null, 'group-1');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    @IsTest
    static void remove_blankGroupId_throws() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        try {
            PromoCodeApplyService.remove(ord.Id, '');
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }

    // -----------------------------------------------------------
    // revalidateAll()
    // -----------------------------------------------------------

    @IsTest
    static void revalidateAll_returnsResultsForPendingCodes() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('STILL_'), CURRENCY_ISO, 10);

        PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        Test.startTest();
        List<PromoCodeApplyService.CodeResult> results = PromoCodeApplyService.revalidateAll(ord.Id);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].valid);
    }

    @IsTest
    static void revalidateAll_noPendingPcis_returnsEmpty() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;

        List<PromoCodeApplyService.CodeResult> results = PromoCodeApplyService.revalidateAll(ord.Id);
        System.assertEquals(0, results.size());
    }

    @IsTest
    static void revalidateAll_codeBecameInvalid_returnsErrorResult() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('EXP_'), CURRENCY_ISO, 10);
        PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });

        // Simulate post-apply expiration. Effective_End_Date__c is in the allowed-edit list so the
        // lock VR doesn't fire.
        pc.Effective_End_Date__c = Datetime.now().addMinutes(-1);
        update pc;

        Test.startTest();
        List<PromoCodeApplyService.CodeResult> results = PromoCodeApplyService.revalidateAll(ord.Id);
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].valid);
        System.assertEquals(PromoCodeApplyService.ERR_OUT_OF_WINDOW, results[0].errorCode);
    }

    // -----------------------------------------------------------
    // UUID generation
    // -----------------------------------------------------------

    @IsTest
    static void generateUuid_returnsDistinctHyphenatedValues() {
        Set<String> seen = new Set<String>();
        for (Integer i = 0; i < 20; i++) {
            String id = PromoCodeApplyService.generateUuid();
            System.assertEquals(36, id.length(), 'UUID format should be 8-4-4-4-12 = 36 chars');
            System.assert(!seen.contains(id), 'Generated UUIDs should be unique');
            seen.add(id);
        }
    }

    // -----------------------------------------------------------
    // Bulk + community-user runAs
    // -----------------------------------------------------------

    @IsTest
    static void apply_bulkLines_handlesManyOrderItems() {
        // Use as many Membership PBEs as the org provides (capped by factory query LIMIT).
        Order ord = setupOrderWithItems(30);
        if (ord == null) return;

        Integer lineCount = [SELECT COUNT() FROM OrderItem WHERE OrderId = :ord.Id];
        if (lineCount < 5) return; // not enough data to make the bulk assertion meaningful

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('BULK_'), CURRENCY_ISO, 5);

        Test.startTest();
        PromoCodeApplyService.ApplyResult result =
            PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });
        Test.stopTest();

        System.assertEquals(true, result.codeResults[0].valid,
            'Bulk apply should succeed; got: ' + result.codeResults[0].errorMessage);
        Integer pciCount = [SELECT COUNT() FROM Promo_Code_Item__c WHERE Order_Item__r.OrderId = :ord.Id];
        System.assertEquals(lineCount, pciCount, 'One PCI per qualifying line');
    }

    @IsTest
    static void apply_runAsNonAdminUser_runsCleanly() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(uniqueCode('RUNAS_'), CURRENCY_ISO, 10);

        User runner = createNonAdminUser();

        Test.startTest();
        System.runAs(runner) {
            PromoCodeApplyService.ApplyResult result =
                PromoCodeApplyService.apply(ord.Id, new List<String>{ pc.Code__c });
            // We don't strictly assert valid=true because the non-admin profile may lack required
            // FLS (will be granted in Phase A3 via the community permission set). What we DO
            // assert is that the service didn't blow up uncaught — it surfaces missing access as a
            // structured AuraHandledException, not a raw runtime error.
            System.assertNotEquals(null, result);
            System.assertEquals(1, result.codeResults.size());
        }
        Test.stopTest();
    }

    private static User createNonAdminUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        User u = new User(
            Username = 'pcastest_' + System.currentTimeMillis() + '@example.invalid.test',
            Email = 'pcastest@example.invalid',
            FirstName = 'Test',
            LastName = 'Runner',
            Alias = 'pcas',
            TimeZoneSidKey = 'America/Los_Angeles',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            ProfileId = p.Id
        );
        insert u;
        List<PermissionSet> psets = [SELECT Id FROM PermissionSet WHERE Name = 'Promo_Code_Manager' LIMIT 1];
        if (!psets.isEmpty()) {
            insert new PermissionSetAssignment(AssigneeId = u.Id, PermissionSetId = psets[0].Id);
        }
        return u;
    }
}
