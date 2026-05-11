/**
 * Tests for PromoCodeAllocationEngine. The engine is pure compute (no DML, no SOQL), so these
 * tests build OrderItems and Promo_Code__c records in-memory and assert on the emitted
 * CodeAllocation list directly. This keeps the suite fast and bypasses org-level flows that
 * would otherwise interfere with Product2 / OrderItem setup.
 *
 * Coverage targets the Application_Level × Product_Scope_Type matrix (8 cases) plus
 * proportionate-distribution math, residual reconciliation, Per Line replication math, stacking,
 * floor-at-subtotal, and Specific Membership Types name-CONTAINS matching.
 */
@IsTest
private class PromoCodeAllocationEngineTest {

    // ============================================================
    // In-memory builders
    // ============================================================

    private static Promo_Code__c buildCode(
        String code, String discountType, Decimal value,
        String applicationLevel, String scopeType,
        String familyScope, String memberTypeScope, String specificProducts
    ) {
        return new Promo_Code__c(
            Id = fakeId(Promo_Code__c.SObjectType),
            Code__c = code,
            Discount_Type__c = discountType,
            Discount_Value__c = value,
            Application_Level__c = applicationLevel,
            Product_Scope_Type__c = scopeType,
            Product_Family_Scope__c = familyScope,
            Member_Type_Scope__c = memberTypeScope,
            Specific_Products__c = specificProducts,
            Combinable__c = true,
            Combination_Group__c = 'General'
        );
    }

    private static OrderItem buildLine(String productName, String family, String productCode, Decimal unitPrice, Decimal qty) {
        OrderItem oi = new OrderItem(
            Id = fakeId(OrderItem.SObjectType),
            UnitPrice = unitPrice,
            Quantity = qty
        );
        oi.Product2 = new Product2(Name = productName, Family = family, ProductCode = productCode);
        return oi;
    }

    private static Integer fakeIdCounter = 0;
    private static Id fakeId(Schema.SObjectType sot) {
        fakeIdCounter += 1;
        String prefix = sot.getDescribe().getKeyPrefix();
        String suffix = String.valueOf(fakeIdCounter).leftPad(12, '0');
        return Id.valueOf(prefix + suffix);
    }

    private static Decimal sumAdjustments(List<PromoCodeAllocationEngine.CodeAllocation> result) {
        Decimal total = 0;
        for (PromoCodeAllocationEngine.CodeAllocation a : result) total += a.adjustmentAmount;
        return total;
    }

    private static Map<Id, Decimal> byLine(List<PromoCodeAllocationEngine.CodeAllocation> result) {
        Map<Id, Decimal> out = new Map<Id, Decimal>();
        for (PromoCodeAllocationEngine.CodeAllocation a : result) {
            Decimal current = out.containsKey(a.orderItemId) ? out.get(a.orderItemId) : 0;
            out.put(a.orderItemId, current + a.adjustmentAmount);
        }
        return out;
    }

    // ============================================================
    // Basic / edge inputs
    // ============================================================

    @IsTest
    static void allocate_emptyInputs_returnsEmpty() {
        System.assertEquals(0, PromoCodeAllocationEngine.allocate(null, null).size());
        System.assertEquals(0,
            PromoCodeAllocationEngine.allocate(
                new List<Promo_Code__c>(),
                new List<OrderItem>{ buildLine('A', 'X', 'A1', 100, 1) }
            ).size()
        );
        System.assertEquals(0,
            PromoCodeAllocationEngine.allocate(
                new List<Promo_Code__c>{ buildCode('X', 'Percent', 10, 'Per Order', 'All Items', null, null, null) },
                new List<OrderItem>()
            ).size()
        );
    }

    @IsTest
    static void allocate_guards_dropsZeroQtyAndZeroPriceLines() {
        Promo_Code__c c = buildCode('PCT10', 'Percent', 10, 'Per Line', 'All Items', null, null, null);
        OrderItem priced = buildLine('A', 'Membership', 'A1', 100, 1);
        OrderItem zeroQty = buildLine('B', 'Membership', 'B1', 100, 0);
        OrderItem freebie = buildLine('C', 'Membership', 'C1', 0, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ priced, zeroQty, freebie }
        );

        System.assertEquals(1, result.size(), 'Only the priced line should receive an allocation');
        System.assertEquals(priced.Id, result[0].orderItemId);
    }

    // ============================================================
    // 8-cell matrix: Application_Level × Product_Scope_Type
    // ============================================================

    @IsTest
    static void perOrder_allItems_distributesProRata() {
        // $50 promo distributed across $200 + $300 → $20 + $30 (per design-overview §5.3 example).
        Promo_Code__c c = buildCode('PO_AI', 'Amount', 50, 'Per Order', 'All Items', null, null, null);
        OrderItem a = buildLine('A', 'Membership', 'A1', 200, 1);
        OrderItem b = buildLine('B', 'Membership', 'B1', 300, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ a, b });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(20.00, m.get(a.Id));
        System.assertEquals(30.00, m.get(b.Id));
        System.assertEquals(50.00, sumAdjustments(result));
    }

    @IsTest
    static void perOrder_productFamily_onlyMatchingLinesShareValue() {
        Promo_Code__c c = buildCode('PO_PF', 'Amount', 50, 'Per Order', 'Product Family',
            'Membership', null, null);
        OrderItem inFam = buildLine('A', 'Membership', 'A1', 200, 1);
        OrderItem outFam = buildLine('B', 'Chapter', 'B1', 300, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ inFam, outFam });

        System.assertEquals(1, result.size());
        System.assertEquals(inFam.Id, result[0].orderItemId);
        System.assertEquals(50.00, result[0].adjustmentAmount,
            'Single eligible line gets full Per Order value (clamped only at line subtotal)');
    }

    @IsTest
    static void perOrder_specificMembershipTypes_containsMatch() {
        // Tokens like "Allied" / "Direct" match against product names CONTAINS, case-insensitive.
        Promo_Code__c c = buildCode('PO_SMT', 'Amount', 60, 'Per Order', 'Specific Membership Types',
            null, 'Allied;Direct', null);
        OrderItem allied = buildLine('Allied Membership', 'Membership', 'ALL-1', 100, 1);
        OrderItem direct = buildLine('Direct Membership', 'Membership', 'DIR-1', 200, 1);
        OrderItem student = buildLine('Student Membership', 'Membership', 'STU-1', 50, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ allied, direct, student });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(2, m.size(), 'Only allied + direct lines match');
        // $60 split across $100 + $200 by pro-rata → $20 + $40.
        System.assertEquals(20.00, m.get(allied.Id));
        System.assertEquals(40.00, m.get(direct.Id));
        System.assertEquals(null, m.get(student.Id));
    }

    @IsTest
    static void perOrder_specificProducts_matchesByProductCodeCaseInsensitive() {
        Promo_Code__c c = buildCode('PO_SP', 'Amount', 30, 'Per Order', 'Specific Products',
            null, null, 'sku-001, SKU-002');
        OrderItem hit1 = buildLine('Allied Membership', 'Membership', 'SKU-001', 100, 1);
        OrderItem hit2 = buildLine('Direct Membership', 'Membership', 'sku-002', 200, 1);
        OrderItem miss = buildLine('Student Membership', 'Membership', 'SKU-099', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ hit1, hit2, miss });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(2, m.size());
        System.assertEquals(10.00, m.get(hit1.Id));
        System.assertEquals(20.00, m.get(hit2.Id));
        System.assertEquals(null, m.get(miss.Id));
    }

    @IsTest
    static void perLine_allItems_replicatesValueToEachLine() {
        // $20 promo × 3 eligible lines = $60 total cart discount.
        Promo_Code__c c = buildCode('PL_AI', 'Amount', 20, 'Per Line', 'All Items', null, null, null);
        OrderItem a = buildLine('A', 'Membership', 'A1', 100, 1);
        OrderItem b = buildLine('B', 'Membership', 'B1', 100, 1);
        OrderItem cLine = buildLine('C', 'Membership', 'C1', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ a, b, cLine });

        System.assertEquals(3, result.size());
        System.assertEquals(60.00, sumAdjustments(result));
        for (PromoCodeAllocationEngine.CodeAllocation alloc : result) {
            System.assertEquals(20.00, alloc.adjustmentAmount);
        }
    }

    @IsTest
    static void perLine_productFamily_replicatesToMatchingLinesOnly() {
        Promo_Code__c c = buildCode('PL_PF', 'Percent', 10, 'Per Line', 'Product Family',
            'Membership;Chapter', null, null);
        OrderItem mem = buildLine('A', 'Membership', 'A1', 100, 1);
        OrderItem ch = buildLine('B', 'Chapter', 'B1', 200, 1);
        OrderItem ev = buildLine('C', 'Event', 'C1', 300, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ mem, ch, ev });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(2, m.size());
        System.assertEquals(10.00, m.get(mem.Id));   // 100 × 10% = 10
        System.assertEquals(20.00, m.get(ch.Id));    // 200 × 10% = 20
        System.assertEquals(null, m.get(ev.Id));
    }

    @IsTest
    static void perLine_specificMembershipTypes_replicatesToTokenMatches() {
        Promo_Code__c c = buildCode('PL_SMT', 'Amount', 10, 'Per Line', 'Specific Membership Types',
            null, 'Premier', null);
        OrderItem premier1 = buildLine('Premier Allied Membership', 'Membership', 'P1', 100, 1);
        OrderItem premier2 = buildLine('premier direct membership', 'Membership', 'P2', 200, 1);
        OrderItem standard = buildLine('Student Membership', 'Membership', 'S1', 50, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ premier1, premier2, standard });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(2, m.size(), 'Case-insensitive CONTAINS match against product Name');
        System.assertEquals(10.00, m.get(premier1.Id));
        System.assertEquals(10.00, m.get(premier2.Id));
    }

    @IsTest
    static void perLine_specificProducts_replicatesToCodeMatches() {
        Promo_Code__c c = buildCode('PL_SP', 'Percent', 5, 'Per Line', 'Specific Products',
            null, null, 'SKU-A,SKU-B');
        OrderItem a = buildLine('Allied Membership', 'Membership', 'SKU-A', 200, 1);
        OrderItem b = buildLine('Direct Membership', 'Membership', 'SKU-B', 400, 1);
        OrderItem skip = buildLine('Student Membership', 'Membership', 'SKU-Z', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ a, b, skip });

        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(2, m.size());
        System.assertEquals(10.00, m.get(a.Id));   // 200 × 5% = 10
        System.assertEquals(20.00, m.get(b.Id));   // 400 × 5% = 20
    }

    // ============================================================
    // Per Order × Percent — targetValue derived from cart subtotal
    // ============================================================

    @IsTest
    static void perOrder_percent_targetValueFromCartSubtotal() {
        // 10% off two lines totaling $400 → targetValue = $40, distributed 200/200 → $20 / $20.
        Promo_Code__c c = buildCode('PO_PCT', 'Percent', 10, 'Per Order', 'All Items', null, null, null);
        OrderItem a = buildLine('A', 'Membership', 'A1', 200, 1);
        OrderItem b = buildLine('B', 'Membership', 'B1', 200, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result =
            PromoCodeAllocationEngine.allocate(new List<Promo_Code__c>{ c }, new List<OrderItem>{ a, b });

        System.assertEquals(40.00, sumAdjustments(result));
        Map<Id, Decimal> m = byLine(result);
        System.assertEquals(20.00, m.get(a.Id));
        System.assertEquals(20.00, m.get(b.Id));
    }

    // ============================================================
    // Distribution math: rounding residual reconciled onto largest line
    // ============================================================

    @IsTest
    static void perOrder_amount_reconcilesRoundingOntoLargestLine() {
        // $10 off across three lines of $33.33, $33.33, $33.34 — rounding could leave a residual
        // cent; the engine must reconcile it onto the largest-subtotal line so totals match.
        Promo_Code__c c = buildCode('ROUND', 'Amount', 10, 'Per Order', 'All Items', null, null, null);
        OrderItem a = buildLine('A', 'Membership', 'A1', 33.33, 1);
        OrderItem b = buildLine('B', 'Membership', 'B1', 33.33, 1);
        OrderItem cLine = buildLine('C', 'Membership', 'C1', 33.34, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ a, b, cLine }
        );

        System.assertEquals(10.00, sumAdjustments(result),
            'Pro-rata + residual reconciliation must sum exactly to targetValue');
    }

    // ============================================================
    // Stacking
    // ============================================================

    @IsTest
    static void stacking_twoPercentCodes_addsToTwentyPercent() {
        // Two 10% codes against one $100 line, both Per Line → $20 total (computed against the
        // original UnitPrice × Quantity, not progressively discounted).
        Promo_Code__c c1 = buildCode('PCT10A', 'Percent', 10, 'Per Line', 'All Items', null, null, null);
        Promo_Code__c c2 = buildCode('PCT10B', 'Percent', 10, 'Per Line', 'All Items', null, null, null);
        OrderItem oi = buildLine('A', 'Membership', 'A1', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c1, c2 },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(2, result.size());
        System.assertEquals(20.00, sumAdjustments(result));
    }

    @IsTest
    static void stacking_floorAtLineSubtotal_capsLargeStack() {
        // $80 + $80 stack on a $100 line — second code can only contribute up to remaining
        // headroom ($20).
        Promo_Code__c c1 = buildCode('A1', 'Amount', 80, 'Per Line', 'All Items', null, null, null);
        Promo_Code__c c2 = buildCode('A2', 'Amount', 80, 'Per Line', 'All Items', null, null, null);
        OrderItem oi = buildLine('X', 'Membership', 'X1', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c1, c2 },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(100.00, sumAdjustments(result),
            'Combined adjustments must not exceed pre-discount subtotal');
    }

    @IsTest
    static void floor_singleHugeDiscount_cappedAtSubtotal() {
        // Per Order × Amount with discountValue > eligible-subtotal → targetValue clamps to
        // totalSubtotal, no negative net.
        Promo_Code__c c = buildCode('BIG', 'Amount', 500, 'Per Order', 'All Items', null, null, null);
        OrderItem oi = buildLine('A', 'Membership', 'A1', 100, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(1, result.size());
        System.assertEquals(100.00, result[0].adjustmentAmount);
    }

    // ============================================================
    // Snapshot fields
    // ============================================================

    @IsTest
    static void allocation_includesApplicationLevelAndScopeSnapshots() {
        Promo_Code__c c = buildCode('SNAP', 'Percent', 10, 'Per Order', 'Product Family',
            'Membership', null, null);
        OrderItem oi = buildLine('A', 'Membership', 'A1', 200, 1);

        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c },
            new List<OrderItem>{ oi }
        );

        System.assertEquals(1, result.size());
        System.assertEquals('Per Order', result[0].applicationLevelSnapshot);
        System.assertEquals('Product Family', result[0].productScopeTypeSnapshot);
        System.assertEquals('Percent', result[0].discountTypeSnapshot);
        System.assertEquals(10, result[0].discountValueSnapshot);
    }

    // ============================================================
    // Bulk-safety
    // ============================================================

    @IsTest
    static void bulk_perLine_50Lines() {
        Promo_Code__c c = buildCode('BULK', 'Percent', 5, 'Per Line', 'All Items', null, null, null);
        List<OrderItem> lines = new List<OrderItem>();
        for (Integer i = 0; i < 50; i++) {
            lines.add(buildLine('P' + i, 'Membership', 'C' + i, 100, 1));
        }

        Test.startTest();
        List<PromoCodeAllocationEngine.CodeAllocation> result = PromoCodeAllocationEngine.allocate(
            new List<Promo_Code__c>{ c }, lines
        );
        Test.stopTest();

        System.assertEquals(50, result.size());
        System.assertEquals(250.00, sumAdjustments(result),
            '50 lines × 5% of $100 = $250');
    }
}
