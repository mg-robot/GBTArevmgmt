/**
 * Test-only utility Apex backing the "Promo Code Entry — Dev Test" Lightning App Page. These
 * methods let staff exercise the apply flow end-to-end while the parent Checkout LWC is still
 * under development:
 *   triggerReprice              — snapshot the current PCIs as a stand-in for the Phase A4 hook
 *   simulatePrePlaceValidation  — calls PromoCodeApplyService.revalidateAll
 *   resetTestData               — wipes all PCIs for an order and clears Promo_Codes_Entered__c
 *
 * Not intended for production use — gated by the Promo_Code_Manager permission set the same way
 * the harness LWC is. Once the parent Checkout LWC + Headless Pricing integration land
 * (Phase A4), the triggerReprice stub here should be replaced with an actual pricing call.
 */
public with sharing class PromoCodeTestHarnessController {

    /**
     * Stand-in for the Phase A4 Headless Pricing call. Returns a JSON snapshot of every PCI on
     * the order so a human can verify the apply / remove cycle landed the right reservations.
     * Replace with a real pricing invocation once the pre-hook + Context Definition are wired.
     */
    @AuraEnabled
    public static String triggerReprice(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Order Id is required.');
        }
        List<Promo_Code_Item__c> pcis = [
            SELECT Id, Promo_Code__r.Code__c, Order_Item__c, Order_Item__r.Product2.Name,
                   Applied_Discount_Amount__c, Status__c, Application_Group_Id__c, Applied_Date__c
            FROM Promo_Code_Item__c
            WHERE Order_Item__r.OrderId = :orderId
            ORDER BY Status__c ASC, Applied_Date__c DESC
        ];
        return JSON.serializePretty(pcis);
    }

    /**
     * Mirrors what the parent Checkout LWC will call before invoking Chargent / Place Sales
     * Transaction. Returns a CodeResult per currently-Pending parent code; any with valid=false
     * have become invalid since Apply and would block placement.
     */
    @AuraEnabled
    public static List<PromoCodeApplyService.CodeResult> simulatePrePlaceValidation(Id orderId) {
        return PromoCodeApplyService.revalidateAll(orderId);
    }

    /**
     * Hard-delete every PCI on the order and clear the entered-codes CSV so a test scenario can
     * be re-run from a clean state. Deletes regardless of Status (Pending, Confirmed, Released).
     */
    @AuraEnabled
    public static String resetTestData(Id orderId) {
        if (orderId == null) {
            throw new AuraHandledException('Order Id is required.');
        }
        List<Promo_Code_Item__c> pcis = [
            SELECT Id FROM Promo_Code_Item__c WHERE Order_Item__r.OrderId = :orderId
        ];
        Integer count = pcis.size();
        if (!pcis.isEmpty()) {
            delete pcis;
        }
        Order o = new Order(Id = orderId, Promo_Codes_Entered__c = null);
        update o;
        return 'Deleted ' + count + ' Promo_Code_Item__c record(s) and cleared Promo_Codes_Entered__c.';
    }
}
