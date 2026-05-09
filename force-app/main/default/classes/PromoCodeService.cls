public with sharing class PromoCodeService {

    public class PromoCodeInput {
        @AuraEnabled public String code;
        @AuraEnabled public String displayName;
        @AuraEnabled public String terms;
        @AuraEnabled public String discountType;
        @AuraEnabled public Decimal percentValue;
        @AuraEnabled public List<String> percentCurrencies;
        @AuraEnabled public List<CurrencyAmount> amounts;
        @AuraEnabled public Datetime effectiveStart;
        @AuraEnabled public Datetime effectiveEnd;
        @AuraEnabled public Decimal totalLimit;
        @AuraEnabled public Decimal perMemberLimit;
        @AuraEnabled public List<String> memberTypeScope;
        @AuraEnabled public List<String> regionScope;
        @AuraEnabled public String productScopeType;
        @AuraEnabled public String specificProducts;
        @AuraEnabled public Id sponsorAccountId;
        @AuraEnabled public Boolean combinable;
        @AuraEnabled public String combinationGroup;
        @AuraEnabled public Boolean approvalRequired;
    }

    public class CurrencyAmount {
        @AuraEnabled public String currencyIsoCode;
        @AuraEnabled public Decimal amount;
    }

    public class CreateResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public List<Id> createdRecordIds;
        @AuraEnabled public String errorMessage;
        @AuraEnabled public List<String> conflictCurrencies;
    }

    public class ProductOption {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String productCode;
    }

    @AuraEnabled(cacheable=true)
    public static List<String> getActiveCurrencies() {
        List<String> currencies = new List<String>();
        if (Schema.getGlobalDescribe().containsKey('CurrencyType')) {
            for (SObject ct : Database.query('SELECT IsoCode FROM CurrencyType WHERE IsActive = true ORDER BY IsoCode')) {
                currencies.add((String) ct.get('IsoCode'));
            }
        } else {
            currencies.add(UserInfo.getDefaultCurrency());
        }
        return currencies;
    }

    @AuraEnabled
    public static List<String> checkCodeUniqueness(String code) {
        List<String> conflicts = new List<String>();
        if (String.isBlank(code)) {
            return conflicts;
        }
        String trimmed = code.trim();
        Boolean isMultiCurrency = Schema.getGlobalDescribe().containsKey('CurrencyType')
            && Schema.SObjectType.Promo_Code__c.fields.getMap().containsKey('currencyisocode');
        String soql = 'SELECT '
            + (isMultiCurrency ? 'CurrencyIsoCode' : 'Id')
            + ' FROM Promo_Code__c WHERE Code__c = :trimmed';
        for (SObject pc : Database.query(soql)) {
            conflicts.add(isMultiCurrency ? (String) pc.get('CurrencyIsoCode') : 'DEFAULT');
        }
        return conflicts;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProductOption> searchProducts(String searchTerm) {
        List<ProductOption> options = new List<ProductOption>();
        if (String.isBlank(searchTerm) || searchTerm.length() < 2) {
            return options;
        }
        String like = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        for (Product2 p : [
            SELECT Id, Name, ProductCode
            FROM Product2
            WHERE IsActive = true
            AND (Name LIKE :like OR ProductCode LIKE :like)
            ORDER BY Name
            LIMIT 20
        ]) {
            ProductOption opt = new ProductOption();
            opt.id = p.Id;
            opt.name = p.Name;
            opt.productCode = p.ProductCode;
            options.add(opt);
        }
        return options;
    }

    @AuraEnabled
    public static CreateResult createBulk(PromoCodeInput input) {
        CreateResult result = new CreateResult();

        if (input == null || String.isBlank(input.code) || String.isBlank(input.displayName) || String.isBlank(input.discountType)) {
            result.success = false;
            result.errorMessage = 'Missing required fields (code, display name, or discount type).';
            return result;
        }

        Boolean isMultiCurrency = Schema.getGlobalDescribe().containsKey('CurrencyType')
            && Schema.SObjectType.Promo_Code__c.fields.getMap().containsKey('currencyisocode');

        Map<String, Decimal> currencyAmountMap = new Map<String, Decimal>();
        if ('Percent'.equalsIgnoreCase(input.discountType)) {
            if (input.percentValue == null || input.percentValue <= 0 || input.percentValue > 100) {
                result.success = false;
                result.errorMessage = 'Percent value must be between 0 and 100.';
                return result;
            }
            List<String> isos = (input.percentCurrencies == null || input.percentCurrencies.isEmpty())
                ? getActiveCurrencies()
                : input.percentCurrencies;
            for (String iso : isos) {
                currencyAmountMap.put(iso, input.percentValue);
            }
        } else if ('Amount'.equalsIgnoreCase(input.discountType)) {
            if (input.amounts == null || input.amounts.isEmpty()) {
                result.success = false;
                result.errorMessage = 'At least one currency-amount pair is required for Amount discounts.';
                return result;
            }
            for (CurrencyAmount ca : input.amounts) {
                if (String.isBlank(ca.currencyIsoCode) || ca.amount == null || ca.amount <= 0) {
                    result.success = false;
                    result.errorMessage = 'Each amount row must have a currency and a value greater than zero.';
                    return result;
                }
                currencyAmountMap.put(ca.currencyIsoCode, ca.amount);
            }
        } else {
            result.success = false;
            result.errorMessage = 'Unknown discount type: ' + input.discountType;
            return result;
        }

        List<String> targetCurrencies = new List<String>(currencyAmountMap.keySet());
        String trimmedCode = input.code.trim();

        if (isMultiCurrency) {
            String soql = 'SELECT CurrencyIsoCode FROM Promo_Code__c '
                + 'WHERE Code__c = :trimmedCode AND CurrencyIsoCode IN :targetCurrencies';
            List<SObject> existing = Database.query(soql);
            if (!existing.isEmpty()) {
                result.success = false;
                result.conflictCurrencies = new List<String>();
                for (SObject pc : existing) {
                    result.conflictCurrencies.add((String) pc.get('CurrencyIsoCode'));
                }
                result.errorMessage = 'Code "' + trimmedCode + '" already exists for: '
                    + String.join(result.conflictCurrencies, ', ');
                return result;
            }
        }

        List<Promo_Code__c> toInsert = new List<Promo_Code__c>();
        for (String iso : targetCurrencies) {
            Promo_Code__c rec = new Promo_Code__c(
                Code__c = trimmedCode,
                Discount_Type__c = input.discountType,
                Discount_Value__c = currencyAmountMap.get(iso),
                Status__c = 'Draft',
                Effective_Start_Date__c = input.effectiveStart,
                Effective_End_Date__c = input.effectiveEnd,
                Total_Usage_Limit__c = input.totalLimit,
                Per_Member_Usage_Limit__c = input.perMemberLimit,
                Member_Type_Scope__c = (input.memberTypeScope == null || input.memberTypeScope.isEmpty())
                    ? null : String.join(input.memberTypeScope, ';'),
                Region_Scope__c = (input.regionScope == null || input.regionScope.isEmpty())
                    ? null : String.join(input.regionScope, ';'),
                Product_Scope_Type__c = input.productScopeType,
                Specific_Products__c = input.specificProducts,
                Sponsor_Account__c = input.sponsorAccountId,
                Combinable__c = input.combinable == true,
                Combination_Group__c = input.combinationGroup,
                Display_Name__c = input.displayName,
                Terms__c = input.terms,
                Approval_Required__c = input.approvalRequired == true
            );
            if (isMultiCurrency) {
                rec.put('CurrencyIsoCode', iso);
            }
            toInsert.add(rec);
        }

        Savepoint sp = Database.setSavepoint();
        try {
            insert toInsert;
            result.success = true;
            result.createdRecordIds = new List<Id>();
            for (Promo_Code__c r : toInsert) {
                result.createdRecordIds.add(r.Id);
            }
            // TODO(GBTAP1-239): if input.approvalRequired == true, submit each record via Approval.process(...)
            //                   once the Promo Code Approval Process metadata is built.
        } catch (DmlException e) {
            Database.rollback(sp);
            result.success = false;
            result.errorMessage = e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage();
        }

        return result;
    }
}
