/**
 * Backing service for the Promotions Home "Promos Pending Activation" tile. Returns the top N
 * Draft Promo_Code__c records by CreatedDate DESC so staff can see what's waiting to be activated
 * and jump straight to the record page.
 *
 * Cacheable: the LWC re-runs on a manual Refresh action; otherwise the wire result is reused.
 *
 * Sharing: with-sharing. Staff users need read access on Promo_Code__c (granted by the
 * Promo_Code_Manager permission set).
 */
public with sharing class PromoCodePendingActivationController {

    public class DraftCodeInfo {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String code;
        @AuraEnabled public String displayName;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public String discountType;
        @AuraEnabled public Decimal discountValue;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public String createdByName;
    }

    /**
     * @param maxRecords cap on rows returned. Null or <=0 defaults to 10.
     * @return up to maxRecords Draft codes ordered by CreatedDate DESC.
     */
    @AuraEnabled(cacheable=true)
    public static List<DraftCodeInfo> getDraftCodes(Integer maxRecords) {
        List<DraftCodeInfo> results = new List<DraftCodeInfo>();
        Integer lim = (maxRecords == null || maxRecords <= 0) ? 10 : maxRecords;

        Boolean isMultiCurrency = Schema.SObjectType.Promo_Code__c.fields.getMap()
            .containsKey('currencyisocode');

        String soql =
            'SELECT Id, Code__c, Display_Name__c, ' +
            (isMultiCurrency ? 'CurrencyIsoCode, ' : '') +
            'Discount_Type__c, Discount_Value__c, CreatedDate, CreatedBy.Name ' +
            'FROM Promo_Code__c ' +
            'WHERE Status__c = \'Draft\' ' +
            'ORDER BY CreatedDate DESC ' +
            'LIMIT :lim';

        for (Promo_Code__c c : (List<Promo_Code__c>) Database.query(soql)) {
            DraftCodeInfo info = new DraftCodeInfo();
            info.recordId = c.Id;
            info.code = c.Code__c;
            info.displayName = c.Display_Name__c;
            info.currencyIsoCode = isMultiCurrency ? (String) c.get('CurrencyIsoCode') : null;
            info.discountType = c.Discount_Type__c;
            info.discountValue = c.Discount_Value__c;
            info.createdDate = c.CreatedDate;
            info.createdByName = c.CreatedBy != null ? c.CreatedBy.Name : null;
            results.add(info);
        }
        return results;
    }
}
