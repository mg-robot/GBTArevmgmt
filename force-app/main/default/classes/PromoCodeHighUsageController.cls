/**
 * Backing service for the Promotions Home "High Usage Promos" tile. Returns the top N currently-
 * usable Active Promo_Code__c records by Confirmed_Usage_Count__c DESC, with the math for the
 * usage % bar pre-computed server-side so the LWC stays presentation-only.
 *
 * "Currently usable" = Status__c = Active AND within Effective_Start_Date..Effective_End_Date.
 * Encoded by the Is_Currently_Usable__c formula field.
 *
 * Cacheable: the LWC re-runs on a manual Refresh action; otherwise the wire result is reused.
 *
 * Sharing: with-sharing. Staff users need read access on Promo_Code__c (granted by the
 * Promo_Code_Manager permission set).
 */
public with sharing class PromoCodeHighUsageController {

    public class UsageStats {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String code;
        @AuraEnabled public String displayName;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public Integer confirmedUsageCount;
        @AuraEnabled public Integer totalUsageLimit;   // null = unlimited
        @AuraEnabled public Decimal usagePercentage;   // null = unlimited
    }

    /**
     * @param maxRecords cap on rows returned. Null or <=0 defaults to 10.
     * @return up to maxRecords currently-usable codes with confirmed usage > 0, ordered by
     *         Confirmed_Usage_Count__c DESC.
     */
    @AuraEnabled(cacheable=true)
    public static List<UsageStats> getTopUsed(Integer maxRecords) {
        List<UsageStats> results = new List<UsageStats>();
        Integer lim = (maxRecords == null || maxRecords <= 0) ? 10 : maxRecords;

        Boolean isMultiCurrency = Schema.SObjectType.Promo_Code__c.fields.getMap()
            .containsKey('currencyisocode');

        String soql =
            'SELECT Id, Code__c, ' +
            (isMultiCurrency ? 'CurrencyIsoCode, ' : '') +
            'Display_Name__c, Confirmed_Usage_Count__c, Total_Usage_Limit__c ' +
            'FROM Promo_Code__c ' +
            'WHERE Is_Currently_Usable__c = true ' +
            'AND Confirmed_Usage_Count__c > 0 ' +
            'ORDER BY Confirmed_Usage_Count__c DESC NULLS LAST ' +
            'LIMIT :lim';

        for (Promo_Code__c c : (List<Promo_Code__c>) Database.query(soql)) {
            UsageStats r = new UsageStats();
            r.recordId = c.Id;
            r.code = c.Code__c;
            r.currencyIsoCode = isMultiCurrency ? (String) c.get('CurrencyIsoCode') : null;
            r.displayName = c.Display_Name__c;
            Decimal used = (c.Confirmed_Usage_Count__c == null) ? 0 : c.Confirmed_Usage_Count__c;
            r.confirmedUsageCount = used.intValue();
            r.totalUsageLimit = (c.Total_Usage_Limit__c == null) ? null : c.Total_Usage_Limit__c.intValue();
            r.usagePercentage = (c.Total_Usage_Limit__c == null || c.Total_Usage_Limit__c == 0)
                ? null
                : ((used / c.Total_Usage_Limit__c) * 100).setScale(1);
            results.add(r);
        }
        return results;
    }
}
