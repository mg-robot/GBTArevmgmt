/**
 * Supports the Promotions Home list view section. Exposes list views for Promo_Code__c
 * so the LWC can render a view-picker dropdown, since LWC wire adapters do not provide
 * a way to enumerate list views dynamically.
 */
public with sharing class PromoCodeListViewService {

    public class ListViewOption {
        @AuraEnabled public String id { get; set; }
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String developerName { get; set; }

        public ListViewOption(ListView lv) {
            this.id = lv.Id;
            this.label = lv.Name;
            this.developerName = lv.DeveloperName;
        }
    }

    @AuraEnabled(cacheable=true)
    public static List<ListViewOption> getPromoCodeListViews() {
        List<ListViewOption> out = new List<ListViewOption>();
        for (ListView lv : [
            SELECT Id, Name, DeveloperName
            FROM ListView
            WHERE SobjectType = 'Promo_Code__c'
            ORDER BY Name ASC
        ]) {
            out.add(new ListViewOption(lv));
        }
        return out;
    }
}
