/**
 * Test fixture factory for the promo code apply flow. Centralizes Account / Order / OrderItem /
 * Product / Promo_Code__c creation so test classes stay focused on assertions rather than
 * boilerplate.
 *
 * Defensive patterns reused from PromoCodeServiceTest:
 * - Person Account record-type lookup is best-effort; falls back to a Business Account when the
 *   org isn't Person-Account enabled (or test context can't find the record type).
 * - Product2 insert is wrapped because the org has a "Product: add to Price Books" Flow that may
 *   fail under some test contexts. When that happens the test should skip rather than fail
 *   spuriously — callers can check the returned record's Id and skip if null.
 *
 * Usage:
 *   Account member = PromoCodeTestDataFactory.newMember();
 *   Order ord = PromoCodeTestDataFactory.newOrder(member, 'USD', 'Direct', 'NA');
 *   List<OrderItem> ois = PromoCodeTestDataFactory.addItems(ord, new Map<String, Decimal>{
 *       'Direct Membership' => 500
 *   });
 *   Promo_Code__c pc = PromoCodeTestDataFactory.newActivePercentCode('TEST10', 'USD', 10);
 */
@IsTest
public class PromoCodeTestDataFactory {

    private static Integer counter = 0;
    private static Pricebook2 cachedCustomPricebook;
    private static Map<String, Product2> cachedProducts = new Map<String, Product2>();

    public static String unique(String prefix) {
        counter += 1;
        return prefix + counter + '_' + String.valueOf(System.currentTimeMillis()).right(6);
    }

    // -----------------------------------------------------------
    // Members (Accounts)
    // -----------------------------------------------------------

    /**
     * Create a Person Account if the org supports them; otherwise a Business Account. Useful
     * when the test doesn't care which model — most validator/allocation tests don't.
     */
    /**
     * Returns a Business Account. The promo code Apex services don't care whether the redeeming
     * Account is Person or Business — they just read Order.AccountId. Tests that specifically need
     * a Person Account should build one inline rather than relying on the factory.
     */
    public static Account newMember() {
        Account a = new Account(Name = 'Test Member ' + unique(''));
        insert a;
        return a;
    }

    public static Account newBusinessAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    // -----------------------------------------------------------
    // Products & Pricebook
    // -----------------------------------------------------------

    /**
     * Get-or-create an active Product2 with both standard- and custom-pricebook PricebookEntries.
     * Returns null if the org's "Product: add to Price Books" Flow blocks the insert under test
     * context. Callers should skip the assertion when that happens.
     */
    public static Product2 ensureProduct(String name, String family, Decimal unitPrice) {
        if (cachedProducts.containsKey(name)) {
            return cachedProducts.get(name);
        }
        Product2 p = new Product2(Name = name, Family = family, IsActive = true);
        try {
            insert p;
        } catch (Exception e) {
            return null;
        }

        PricebookEntry stdPbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = p.Id,
            UnitPrice = unitPrice,
            IsActive = true
        );
        try {
            insert stdPbe;
        } catch (Exception e) {
            return null;
        }

        Pricebook2 customPb = ensureCustomPricebook();
        if (customPb != null) {
            try {
                insert new PricebookEntry(
                    Pricebook2Id = customPb.Id,
                    Product2Id = p.Id,
                    UnitPrice = unitPrice,
                    IsActive = true
                );
            } catch (Exception e) {
                // Custom PBE is optional — Order can still ride the standard pricebook.
            }
        }

        cachedProducts.put(name, p);
        return p;
    }

    private static Pricebook2 ensureCustomPricebook() {
        if (cachedCustomPricebook != null) return cachedCustomPricebook;
        List<Pricebook2> existing = [SELECT Id FROM Pricebook2 WHERE Name = 'Promo Code Test PB' LIMIT 1];
        if (!existing.isEmpty()) {
            cachedCustomPricebook = existing[0];
            return cachedCustomPricebook;
        }
        Pricebook2 pb = new Pricebook2(Name = 'Promo Code Test PB', IsActive = true);
        try {
            insert pb;
            cachedCustomPricebook = pb;
        } catch (Exception e) {
            return null;
        }
        return cachedCustomPricebook;
    }

    // -----------------------------------------------------------
    // Orders & OrderItems
    // -----------------------------------------------------------

    /**
     * @param memberType unused in v1 — Order.Primary_Type__c is a separate vocabulary not used by
     *                   the validator. The parameter is kept for backwards-compat with test call
     *                   sites; pass any value (or null).
     * @param region     desired Region__c value. Restricted picklist; if the value isn't in the
     *                   org's active picklist, the factory falls back to the first active value
     *                   (so tests aren't tied to a specific org's value set).
     */
    public static Order newOrder(Account member, String currencyIso, String memberType, String region) {
        Order o = new Order(
            AccountId = member.Id,
            EffectiveDate = Date.today(),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            Region__c = pickValidRegion(region)
        );
        if (Schema.SObjectType.Order.fields.getMap().containsKey('currencyisocode') && currencyIso != null) {
            o.put('CurrencyIsoCode', currencyIso);
        }
        insert o;
        return o;
    }

    /**
     * Resolve a usable Region__c picklist value. Returns the requested value if it's active in
     * the org; otherwise falls back to the first active value; null if the picklist has none.
     */
    public static String pickValidRegion(String desired) {
        Schema.DescribeFieldResult dfr = Order.Region__c.getDescribe();
        String firstActive = null;
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (!pe.isActive()) continue;
            if (firstActive == null) firstActive = pe.getValue();
            if (desired != null && pe.getValue().equalsIgnoreCase(desired)) return pe.getValue();
        }
        return firstActive;
    }

    /**
     * Find an active Region__c picklist value that is NOT the supplied one. Used by tests that
     * need an explicit mismatch for REGION_INELIGIBLE. Returns null if no such value exists.
     */
    public static String pickRegionOtherThan(String exclude) {
        Schema.DescribeFieldResult dfr = Order.Region__c.getDescribe();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (!pe.isActive()) continue;
            if (exclude == null || !pe.getValue().equalsIgnoreCase(exclude)) return pe.getValue();
        }
        return null;
    }

    /**
     * Insert one OrderItem per entry in productNameToUnitPrice. Each product is auto-created if
     * needed. Family defaults to 'Membership' but callers can override per-product via
     * ensureProduct() before calling.
     *
     * Returns the inserted OrderItems, in the same order as the map's keys (caller may want to
     * map back to known products). If any product fails to insert (Flow block) the corresponding
     * line is skipped.
     */
    public static List<OrderItem> addItems(Order o, Map<String, Decimal> productNameToUnitPrice) {
        List<OrderItem> toInsert = new List<OrderItem>();
        for (String productName : productNameToUnitPrice.keySet()) {
            Decimal price = productNameToUnitPrice.get(productName);
            Product2 prod = ensureProduct(productName, 'Membership', price);
            if (prod == null) continue;
            PricebookEntry pbe = [
                SELECT Id FROM PricebookEntry
                WHERE Product2Id = :prod.Id AND Pricebook2Id = :Test.getStandardPricebookId()
                LIMIT 1
            ];
            toInsert.add(new OrderItem(
                OrderId = o.Id,
                PricebookEntryId = pbe.Id,
                Product2Id = prod.Id,
                Quantity = 1,
                UnitPrice = price
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
        return toInsert;
    }

    /**
     * Use existing Membership Product2 records (with their existing PricebookEntries) to set up
     * an Order with `count` line items. Requires the calling test to be `@IsTest(SeeAllData=true)`
     * so we can read pre-existing org data — necessary because the org's
     * "Product: add to Price Books" Flow blocks fresh Product2 inserts under test context.
     *
     * Returns the inserted OrderItems. Empty list if the org has no Membership products with
     * PricebookEntries — the caller should skip the test in that case.
     */
    public static List<OrderItem> addItemsFromExistingMembershipProducts(Order o, Integer count) {
        if (count == null || count < 1) count = 1;

        List<PricebookEntry> pbes = [
            SELECT Id, Pricebook2Id, Product2Id, UnitPrice, Product2.Name
            FROM PricebookEntry
            WHERE IsActive = true
              AND Product2.IsActive = true
              AND Product2.Family = 'Membership'
              AND Pricebook2.IsActive = true
            ORDER BY Product2.Name
            LIMIT :count
        ];
        if (pbes.isEmpty()) return new List<OrderItem>();

        // The Order must ride the same Pricebook as the PBEs. Migrate it if it's currently on a
        // different one (e.g., Standard) — that's a quick UPDATE on the empty cart.
        Id targetPb = pbes[0].Pricebook2Id;
        if (o.Pricebook2Id != targetPb) {
            o.Pricebook2Id = targetPb;
            update o;
        }

        List<OrderItem> toInsert = new List<OrderItem>();
        for (PricebookEntry pbe : pbes) {
            if (pbe.Pricebook2Id != targetPb) continue; // mixed-pricebook protection
            toInsert.add(new OrderItem(
                OrderId = o.Id,
                PricebookEntryId = pbe.Id,
                Product2Id = pbe.Product2Id,
                Quantity = 1,
                UnitPrice = pbe.UnitPrice
            ));
        }
        if (!toInsert.isEmpty()) insert toInsert;
        return toInsert;
    }

    /**
     * Returns the Name of the first Membership product the caller can use. Useful for tests that
     * need to put a known-existing product name into Specific_Products__c or Member_Type_Scope__c.
     */
    public static String firstMembershipProductName() {
        List<Product2> hits = [
            SELECT Name FROM Product2
            WHERE IsActive = true AND Family = 'Membership'
            ORDER BY Name LIMIT 1
        ];
        return hits.isEmpty() ? null : hits[0].Name;
    }

    // -----------------------------------------------------------
    // Promo Codes
    // -----------------------------------------------------------

    public static Promo_Code__c newActivePercentCode(String code, String currencyIso, Decimal percent) {
        return insertPromoCode(buildBase(code, currencyIso, 'Percent', percent));
    }

    public static Promo_Code__c newActiveAmountCode(String code, String currencyIso, Decimal amount) {
        return insertPromoCode(buildBase(code, currencyIso, 'Amount', amount));
    }

    public static Promo_Code__c newDraftCode(String code, String currencyIso) {
        Promo_Code__c pc = buildBase(code, currencyIso, 'Percent', 10);
        pc.Status__c = 'Draft';
        return insertPromoCode(pc);
    }

    /**
     * Builder for codes with scoping / limits — caller mutates and re-saves.
     */
    public static Promo_Code__c buildBase(String code, String currencyIso, String discountType, Decimal value) {
        Promo_Code__c pc = new Promo_Code__c(
            Code__c = code,
            Display_Name__c = code,
            Discount_Type__c = discountType,
            Discount_Value__c = value,
            Status__c = 'Active',
            Effective_Start_Date__c = Datetime.now().addMinutes(-5),
            Effective_End_Date__c = Datetime.now().addDays(30),
            Product_Scope_Type__c = 'All Items',
            Combinable__c = true,
            Combination_Group__c = 'General',
            Approval_Required__c = false
        );
        if (Schema.SObjectType.Promo_Code__c.fields.getMap().containsKey('currencyisocode') && currencyIso != null) {
            pc.put('CurrencyIsoCode', currencyIso);
        }
        return pc;
    }

    public static Promo_Code__c insertPromoCode(Promo_Code__c pc) {
        insert pc;
        return pc;
    }

    // -----------------------------------------------------------
    // Pending PCIs (used for usage-count / re-apply tests)
    // -----------------------------------------------------------

    public static Promo_Code_Item__c newPendingPci(
        Promo_Code__c parent,
        OrderItem oi,
        Account member,
        Decimal appliedAmount
    ) {
        Promo_Code_Item__c pci = new Promo_Code_Item__c(
            Promo_Code__c = parent.Id,
            Order_Item__c = oi.Id,
            Member__c = member == null ? null : member.Id,
            Applied_Discount_Amount__c = appliedAmount,
            Discount_Type_Snapshot__c = parent.Discount_Type__c,
            Discount_Value_Snapshot__c = parent.Discount_Value__c,
            Application_Group_Id__c = 'TEST-GROUP-' + unique(''),
            Applied_Date__c = Datetime.now(),
            Status__c = 'Pending'
        );
        insert pci;
        return pci;
    }
}
