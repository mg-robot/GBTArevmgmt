/**
 * Tests for PromoCodePricingPreHook. The platform classes RevSignaling.TransactionRequest /
 * Context.IndustriesContext aren't constructable in test context, so:
 *
 *  - The null-request path of execute() is the only execute()-level coverage we can get
 *  - The real coverage comes from the extracted helpers (extractOrderItemPaths,
 *    aggregateAdjustments, buildNodeUpdates) which are pure-compute @TestVisible methods
 *
 * Full end-to-end coverage happens manually via the "Promo Code Entry — Dev Test" Lightning
 * App Page once the Procedure Plan Definition is wired up in the org.
 */
@IsTest(SeeAllData=true)
private class PromoCodePricingPreHookTest {

    private static final String CURRENCY_ISO = 'USD';

    // -----------------------------------------------------------------------
    // execute() — only the null-guard is testable without a real pricing context
    // -----------------------------------------------------------------------

    @IsTest
    static void execute_nullRequest_returnsFailed() {
        Test.startTest();
        PromoCodePricingPreHook hook = new PromoCodePricingPreHook();
        RevSignaling.TransactionResponse response = hook.execute(null);
        Test.stopTest();

        System.assertEquals(RevSignaling.TransactionStatus.FAILED, response.status);
        System.assert(response.message.contains('missing context'),
            'Expected missing-context message; got: ' + response.message);
    }

    @IsTest
    static void execute_bogusContextId_routesThroughCatch() {
        // RevSignaling.TransactionRequest has no public no-arg constructor — use
        // JSON.deserialize to build one for coverage of the try-block + catch-block paths.
        // A bogus contextId will be rejected by Context.IndustriesContext.queryTags, which
        // surfaces as FAILED via the catch handler.
        RevSignaling.TransactionRequest request;
        try {
            request = (RevSignaling.TransactionRequest) JSON.deserialize(
                '{"ctxInstanceId":"bogus-' + System.currentTimeMillis() + '"}',
                RevSignaling.TransactionRequest.class
            );
        } catch (Exception e) {
            // If deserialization isn't supported either, we can't exercise this path in unit
            // tests — that's a known coverage limitation documented in the class header.
            return;
        }

        Test.startTest();
        PromoCodePricingPreHook hook = new PromoCodePricingPreHook();
        RevSignaling.TransactionResponse response = hook.execute(request);
        Test.stopTest();

        System.assertNotEquals(null, response);
        System.assertNotEquals(null, response.status);
    }

    // -----------------------------------------------------------------------
    // extractOrderItemPaths
    // -----------------------------------------------------------------------

    @IsTest
    static void extractOrderItemPaths_nullList_returnsEmpty() {
        Map<Id, List<Object>> result = PromoCodePricingPreHook.extractOrderItemPaths(null);
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void extractOrderItemPaths_validNodes_returnsMap() {
        Id oi1 = fakeId(OrderItem.SObjectType, 1);
        Id oi2 = fakeId(OrderItem.SObjectType, 2);

        List<Object> nodes = new List<Object>{
            buildNode(oi1, new List<Object>{ 'Order/abc', 'Item/x', 'Line/0' }),
            buildNode(oi2, new List<Object>{ 'Order/abc', 'Item/x', 'Line/1' })
        };

        Map<Id, List<Object>> result = PromoCodePricingPreHook.extractOrderItemPaths(nodes);
        System.assertEquals(2, result.size());
        System.assert(result.containsKey(oi1));
        System.assert(result.containsKey(oi2));
        System.assertEquals(3, result.get(oi1).size());
    }

    @IsTest
    static void extractOrderItemPaths_skipsNodesWithoutLineItemTag() {
        List<Object> nodes = new List<Object>{
            new Map<String, Object>{
                'tagValue' => new Map<String, Object>{ /* no LineItem key */ },
                'dataPath' => new List<Object>{ 'Order/abc', 'Item/x', 'Line/0' }
            }
        };
        Map<Id, List<Object>> result = PromoCodePricingPreHook.extractOrderItemPaths(nodes);
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void extractOrderItemPaths_skipsNullOrderItemId() {
        List<Object> nodes = new List<Object>{
            new Map<String, Object>{
                'tagValue' => new Map<String, Object>{
                    'LineItem' => new Map<String, Object>{ 'tagValue' => null }
                },
                'dataPath' => new List<Object>{ 'a', 'b', 'c' }
            }
        };
        Map<Id, List<Object>> result = PromoCodePricingPreHook.extractOrderItemPaths(nodes);
        System.assertEquals(0, result.size());
    }

    // -----------------------------------------------------------------------
    // aggregateAdjustments
    // -----------------------------------------------------------------------

    @IsTest
    static void aggregateAdjustments_emptyInput_returnsEmpty() {
        Map<Id, Decimal> result = PromoCodePricingPreHook.aggregateAdjustments(new Set<Id>());
        System.assertEquals(0, result.size());

        result = PromoCodePricingPreHook.aggregateAdjustments(null);
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void aggregateAdjustments_sumsAcrossMultiplePcis() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];

        Promo_Code__c pc1 = PromoCodeTestDataFactory.newActivePercentCode(
            'PREHOOK1_' + suffix(), CURRENCY_ISO, 10);
        Promo_Code__c pc2 = PromoCodeTestDataFactory.newActivePercentCode(
            'PREHOOK2_' + suffix(), CURRENCY_ISO, 10);

        // Two pending PCIs on the same OrderItem
        Account member = [SELECT Id FROM Account WHERE Id = :ord.AccountId];
        PromoCodeTestDataFactory.newPendingPci(pc1, oi, member, 25);
        PromoCodeTestDataFactory.newPendingPci(pc2, oi, member, 15);

        Test.startTest();
        Map<Id, Decimal> result = PromoCodePricingPreHook.aggregateAdjustments(new Set<Id>{ oi.Id });
        Test.stopTest();

        System.assertEquals(1, result.size());
        System.assertEquals(40, result.get(oi.Id), 'Expected 25 + 15 aggregated');
    }

    @IsTest
    static void aggregateAdjustments_ignoresNonPendingPcis() {
        Order ord = setupOrderWithOneItem();
        if (ord == null) return;
        OrderItem oi = [SELECT Id FROM OrderItem WHERE OrderId = :ord.Id LIMIT 1];

        Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode(
            'PREHOOK3_' + suffix(), CURRENCY_ISO, 10);
        Account member = [SELECT Id FROM Account WHERE Id = :ord.AccountId];

        Promo_Code_Item__c pending = PromoCodeTestDataFactory.newPendingPci(pc, oi, member, 50);
        Promo_Code_Item__c released = PromoCodeTestDataFactory.newPendingPci(pc, oi, member, 30);
        released.Status__c = 'Released';
        released.Released_Date__c = Datetime.now();
        released.Release_Reason__c = 'Code Removed';
        update released;

        Test.startTest();
        Map<Id, Decimal> result = PromoCodePricingPreHook.aggregateAdjustments(new Set<Id>{ oi.Id });
        Test.stopTest();

        System.assertEquals(50, result.get(oi.Id),
            'Released PCI should be excluded; only Pending counts');
    }

    // -----------------------------------------------------------------------
    // buildNodeUpdates
    // -----------------------------------------------------------------------

    @IsTest
    static void buildNodeUpdates_emptyInput_returnsEmpty() {
        List<Map<String, Object>> result = PromoCodePricingPreHook.buildNodeUpdates(
            new Set<Id>(), new Map<Id, List<Object>>(), new Map<Id, Decimal>()
        );
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void buildNodeUpdates_writesAdjustmentForOrderItemWithPci() {
        Id oi = fakeId(OrderItem.SObjectType, 1);
        List<Object> path = new List<Object>{ 'Order/abc', 'Item/x', 'Line/0' };

        List<Map<String, Object>> result = PromoCodePricingPreHook.buildNodeUpdates(
            new Set<Id>{ oi },
            new Map<Id, List<Object>>{ oi => path },
            new Map<Id, Decimal>{ oi => 42.50 }
        );

        System.assertEquals(1, result.size());
        Map<String, Object> entry = result[0];
        List<Object> attrs = (List<Object>) entry.get('attributes');
        Map<String, Object> attr = (Map<String, Object>) attrs[0];
        System.assertEquals('Promotion_Value__c', attr.get('attributeName'));
        System.assertEquals('42.50', attr.get('attributeValue'));
    }

    @IsTest
    static void buildNodeUpdates_resetsOrderItemWithoutPci() {
        // The whole point of the reset pattern: an OrderItem with no Pending PCIs still gets a
        // node update with Promotion_Value__c=0 so any prior promo state on the OrderItem
        // record gets cleared on the next pricing run.
        Id oi = fakeId(OrderItem.SObjectType, 1);
        List<Object> path = new List<Object>{ 'Order/abc', 'Item/x', 'Line/0' };

        List<Map<String, Object>> result = PromoCodePricingPreHook.buildNodeUpdates(
            new Set<Id>{ oi },
            new Map<Id, List<Object>>{ oi => path },
            new Map<Id, Decimal>{} // no adjustments
        );

        System.assertEquals(1, result.size(), 'OrderItem without PCIs should still get a reset entry');
        Map<String, Object> entry = result[0];
        List<Object> attrs = (List<Object>) entry.get('attributes');
        Map<String, Object> attr = (Map<String, Object>) attrs[0];
        System.assertEquals('0', attr.get('attributeValue'), 'Reset value should be 0');
    }

    @IsTest
    static void buildNodeUpdates_skipsShortDataPaths() {
        Id oi = fakeId(OrderItem.SObjectType, 1);
        List<Object> shortPath = new List<Object>{ 'Order/abc' }; // only 1 element

        List<Map<String, Object>> result = PromoCodePricingPreHook.buildNodeUpdates(
            new Set<Id>{ oi },
            new Map<Id, List<Object>>{ oi => shortPath },
            new Map<Id, Decimal>{ oi => 10 }
        );

        System.assertEquals(0, result.size(),
            'Malformed dataPath should be skipped rather than throwing');
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    private static Order setupOrderWithOneItem() {
        Account member = PromoCodeTestDataFactory.newMember();
        Order ord = PromoCodeTestDataFactory.newOrder(member, CURRENCY_ISO, null, null);
        List<OrderItem> ois = PromoCodeTestDataFactory.addItemsFromExistingMembershipProducts(ord, 1);
        if (ois.isEmpty()) return null;
        return ord;
    }

    private static Map<String, Object> buildNode(Id orderItemId, List<Object> dataPath) {
        return new Map<String, Object>{
            'tagValue' => new Map<String, Object>{
                'LineItem' => new Map<String, Object>{ 'tagValue' => orderItemId }
            },
            'dataPath' => dataPath
        };
    }

    private static String suffix() {
        return String.valueOf(System.currentTimeMillis()).right(8);
    }

    private static Integer fakeIdCounter = 0;
    private static Id fakeId(Schema.SObjectType sot, Integer seed) {
        fakeIdCounter += 1;
        String prefix = sot.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(seed * 1000 + fakeIdCounter).leftPad(12, '0');
        return Id.valueOf(prefix + suffix);
    }
}
