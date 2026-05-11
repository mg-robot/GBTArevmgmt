/**
 * Tests for PromoCodeAllocationEngine. The engine is pure compute (no DML, no SOQL), so these
 * tests build OrderItems and Promo_Code__c records in-memory and assert on the emitted
 * CodeAllocation list directly. This keeps the test suite fast and bypasses org-level flows
 * that would otherwise interfere with Product2 / OrderItem setup.
 */
@IsTest
private class PromoCodeAllocationEngineTest {

    private static Promo_Code__c buildCode(String code, String type, Decimal value, String scopeType, String spec) {
        return new Promo_Code__c(
            Id = fakeId(Promo_Code__c.SObjectType),
            Code__c = code,
            Discount_Type__c = type,
            Discount_Value__c = value,
            Product_Scope_Type__c = scopeType,
            Specific_Products__c = spec,
            Combinable__c = true,
            Combination_Group__c = 'General'
        );
    }

    private static OrderItem buildLine(String productName, String family, Decimal unitPrice, Decimal qty) {
        OrderItem oi = new OrderItem(
            Id = fakeId(OrderItem.SObjectType),
            UnitPrice = unitPrice,
            Quantity = qty
        );
        // Apex allows setting parent-relationship on an in-memory child record via constructor
        // for read-only relationship traversal in tests.
        oi.Product2 = new Product2(Name = productName, Family = family);
        return oi;
    }

    private static Integer fakeIdCounter = 0;
    private static Id fakeId(Schema.SObjectType sot) {
        fakeIdCounter += 1;
        String prefix = sot.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(fakeIdCounter).leftPad(12, '0');
        return Id.valueOf(prefix + suffix);
    }

    @IsTest
    static void allocate_emptyInputs_returnsEmpty() {
        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(null, null);
        System.assertEquals(0, result.size());

        result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>(),
            new List<OrderItem>{ buildLine('A', 'X', 100, 1) }
        );
        System.assertEquals(0, result.size());
    }

    @IsTest
    static void allocate_percentSingleLine_appliesPercentToLine() {
        Promo_Code__c c = buildCode('PCT10', 'Percent', 10, 'All Items', null);
        OrderItem oi = buildLine('Membership', 'Membership', 200, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ oi });

        System.assertEquals(1, result.size());
        System.assertEquals(20.00, result[0].adjustmentAmount);
        System.assertEquals(oi.Id, result[0].orderItemId);
        System.assertEquals('Percent', result[0].discountTypeSnapshot);
    }

    @IsTest
    static void allocate_amountSingleLine_appliesFullAmount() {
        Promo_Code__c c = buildCode('AMT25', 'Amount', 25, 'All Items', null);
        OrderItem oi = buildLine('Membership', 'Membership', 200, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ oi });

        System.assertEquals(1, result.size());
        System.assertEquals(25.00, result[0].adjustmentAmount);
    }

    @IsTest
    static void allocate_amountProRata_splitsAcrossTwoLines() {
        // $50 off, two lines of $200 and $300 → $20 + $30 (per design doc §5.3 example).
        Promo_Code__c c = buildCode('AMT50', 'Amount', 50, 'All Items', null);
        OrderItem line1 = buildLine('A', 'Membership', 200, 1);
        OrderItem line2 = buildLine('B', 'Membership', 300, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ line1, line2 });

        System.assertEquals(2, result.size());

        Map<Id, Decimal> byLine = new Map<Id, Decimal>();
        for (PromoCodeAllocationEngine.CodeAllocation a : result) {
            byLine.put(a.orderItemId, a.adjustmentAmount);
        }
        System.assertEquals(20.00, byLine.get(line1.Id));
        System.assertEquals(30.00, byLine.get(line2.Id));
    }

    @IsTest
    static void allocate_stackingAdditive_twoPercentCodes() {
        // Two 10% codes on one $100 line → $20 total (computed against original UnitPrice).
        Promo_Code__c c1 = buildCode('PCT10A', 'Percent', 10, 'All Items', null);
        Promo_Code__c c2 = buildCode('PCT10B', 'Percent', 10, 'All Items', null);
        OrderItem oi = buildLine('A', 'Membership', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c1, c2 },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(2, result.size());
        Decimal total = 0;
        for (PromoCodeAllocationEngine.CodeAllocation a : result) total += a.adjustmentAmount;
        System.assertEquals(20.00, total);
    }

    @IsTest
    static void allocate_floorAtSubtotal_largeDiscountCapped() {
        // $500 off code against a $100 line → only $100 allocated (no negative net).
        Promo_Code__c c = buildCode('BIGAMT', 'Amount', 500, 'All Items', null);
        OrderItem oi = buildLine('A', 'Membership', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(1, result.size());
        System.assertEquals(100.00, result[0].adjustmentAmount);
    }

    @IsTest
    static void allocate_filterByProductFamily_skipsNonMatchingLines() {
        Promo_Code__c c = buildCode('FAMONLY', 'Percent', 10, 'Product Family', 'Membership');
        OrderItem inFamily = buildLine('A', 'Membership', 100, 1);
        OrderItem outOfFamily = buildLine('B', 'Chapter', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ inFamily, outOfFamily }
        );

        System.assertEquals(1, result.size());
        System.assertEquals(inFamily.Id, result[0].orderItemId);
    }

    @IsTest
    static void allocate_filterBySpecificProducts_matchesByName() {
        Promo_Code__c c = buildCode('SPECIFIC', 'Percent', 10, 'Specific Products', 'Allied Membership, Direct Membership');
        OrderItem match1 = buildLine('Allied Membership', 'Membership', 100, 1);
        OrderItem match2 = buildLine('Direct Membership', 'Membership', 200, 1);
        OrderItem noMatch = buildLine('Student Membership', 'Membership', 50, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ match1, match2, noMatch }
        );

        System.assertEquals(2, result.size());
        Set<Id> hitIds = new Set<Id>();
        for (PromoCodeAllocationEngine.CodeAllocation a : result) hitIds.add(a.orderItemId);
        System.assert(hitIds.contains(match1.Id));
        System.assert(hitIds.contains(match2.Id));
        System.assert(!hitIds.contains(noMatch.Id));
    }

    @IsTest
    static void allocate_bulk_handles50Lines() {
        Promo_Code__c c = buildCode('BULK', 'Percent', 5, 'All Items', null);
        List<OrderItem> lines = new List<OrderItem>();
        for (Integer i = 0; i < 50; i++) {
            lines.add(buildLine('P' + i, 'Membership', 100, 1));
        }
        Test.startTest();
        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c }, lines
        );
        Test.stopTest();
        System.assertEquals(50, result.size());
        for (PromoCodeAllocationEngine.CodeAllocation a : result) {
            System.assertEquals(5.00, a.adjustmentAmount);
        }
    }

    @IsTest
    static void allocate_amountProRata_reconcilesRoundingOntoLargestLine() {
        // $10 off against three lines of $33.33, $33.33, $33.34 — pro-rata may produce
        // $3.33 + $3.33 + $3.34 (sums to $10.00), or rounding leaves a remainder that gets
        // pushed onto the largest line. Either way, the total must equal $10.
        Promo_Code__c c = buildCode('ROUND', 'Amount', 10, 'All Items', null);
        OrderItem a = buildLine('A', 'Membership', 33.33, 1);
        OrderItem b = buildLine('B', 'Membership', 33.33, 1);
        OrderItem cLine = buildLine('C', 'Membership', 33.34, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ a, b, cLine }
        );

        Decimal total = 0;
        for (PromoCodeAllocationEngine.CodeAllocation alloc : result) total += alloc.adjustmentAmount;
        System.assertEquals(10.00, total, 'Pro-rata + reconciliation should sum to the discount amount');
    }
}
