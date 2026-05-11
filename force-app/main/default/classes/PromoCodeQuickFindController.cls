/**
 * Backing service for the Promotions Home "Quick Find Promo Code" tile. Returns matching
 * Promo_Code__c records by exact-uppercase Code__c match, sorted by CurrencyIsoCode so the
 * LWC can present a stable list when one code value exists across multiple currencies.
 *
 * Cacheable: the LWC re-queries via imperative Apex (not @wire) on each submit, so caching is
 * fine — repeat searches for the same term within a short window get served from cache.
 *
 * Sharing: with-sharing. Staff users need read access on Promo_Code__c (granted by the
 * Promo_Code_Manager permission set).
 */
public with sharing class PromoCodeQuickFindController {

    public class MatchResult {
        @AuraEnabled public Id recordId;
        @AuraEnabled public String code;
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public String displayName;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean isCurrentlyUsable;
    }

    /**
     * @param searchTerm the exact Code__c value to find. Whitespace-trimmed and upper-cased before
     *                   the SOQL match — staff typing 'save10' matches 'SAVE10'.
     * @return one MatchResult per matching record (multi-currency codes return one per currency).
     *         Empty list if input is blank or no records match. Max 50 rows.
     */
    @AuraEnabled(cacheable=true)
    public static List<MatchResult> findByCode(String searchTerm) {
        List<MatchResult> results = new List<MatchResult>();
        if (String.isBlank(searchTerm)) return results;
        String normalized = searchTerm.trim().toUpperCase();

        Boolean isMultiCurrency = Schema.SObjectType.Promo_Code__c.fields.getMap()
            .containsKey('currencyisocode');

        String soql =
            'SELECT Id, Code__c, ' +
            (isMultiCurrency ? 'CurrencyIsoCode, ' : '') +
            'Display_Name__c, Status__c, Is_Currently_Usable__c ' +
            'FROM Promo_Code__c ' +
            'WHERE Code__c = :normalized ' +
            (isMultiCurrency ? 'ORDER BY CurrencyIsoCode ' : 'ORDER BY Name ') +
            'LIMIT 50';

        for (Promo_Code__c c : (List<Promo_Code__c>) Database.query(soql)) {
            MatchResult r = new MatchResult();
            r.recordId = c.Id;
            r.code = c.Code__c;
            r.currencyIsoCode = isMultiCurrency ? (String) c.get('CurrencyIsoCode') : null;
            r.displayName = c.Display_Name__c;
            r.status = c.Status__c;
            r.isCurrentlyUsable = c.Is_Currently_Usable__c;
            results.add(r);
        }
        return results;
    }
}
