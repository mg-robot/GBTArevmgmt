/**
 * Apex service backing the Promo Code creation wizard (Membership Ops staff path).
 *
 * Responsibilities:
 * - getActiveCurrencies(): active CurrencyType ISO codes for the wizard currency picker.
 * - checkCodeUniqueness(code): which currencies (if any) already use a given code; used by the
 *   wizard for real-time feedback as the user types.
 * - searchProducts(searchTerm): Product2 typeahead for the Specific Products picker (matches on
 *   Name or ProductCode; per data-model.md, the selected value stored on Specific_Products__c is
 *   Product2.Name).
 * - createBulk(input): single-transaction insert of N Promo_Code__c records (one per selected
 *   currency) sharing the same Code value. Status is Active when input.activateImmediately = true,
 *   else Draft. Composite uniqueness on (Code__c, CurrencyIsoCode) is pre-checked inside the
 *   transaction so duplicate creates fail with a clean conflictCurrencies list (not a DML error).
 *
 * Notes:
 * - Approval_Required__c is captured on the record as a TRANSACTION-RUNTIME flag, consumed by the
 *   apply flow when an order uses this code. It is NOT a record-level approval workflow on the
 *   Promo_Code__c itself. See design-overview.md §8.4.
 * - Composite uniqueness is enforced here for the wizard path; non-wizard insert paths
 *   (Data Loader, direct API) currently bypass this check. See data-model.md §Composite uniqueness
 *   for the alternative Before-Save Flow safety net (future enhancement).
 *
 * Related docs:
 * - docs/promo-code/creation-wizard.md §5 (Apex contract), §6 (Save sequence)
 * - docs/promo-code/design-overview.md §7.3 (technical implementation)
 */
public with sharing class PromoCodeService {

    public class PromoCodeInput {
        @AuraEnabled public String code { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String terms { get; set; }
        @AuraEnabled public String discountType { get; set; }
        @AuraEnabled public Decimal percentValue { get; set; }
        @AuraEnabled public List<String> percentCurrencies { get; set; }
        @AuraEnabled public List<CurrencyAmount> amounts { get; set; }
        @AuraEnabled public Datetime effectiveStart { get; set; }
        @AuraEnabled public Datetime effectiveEnd { get; set; }
        @AuraEnabled public Decimal totalLimit { get; set; }
        @AuraEnabled public Decimal perMemberLimit { get; set; }
        @AuraEnabled public List<String> memberTypeScope { get; set; }
        @AuraEnabled public List<String> regionScope { get; set; }
        @AuraEnabled public String applicationLevel { get; set; }
        @AuraEnabled public String productScopeType { get; set; }
        @AuraEnabled public List<String> productFamilyScope { get; set; }
        @AuraEnabled public String specificProducts { get; set; }
        @AuraEnabled public Id accountId { get; set; }
        @AuraEnabled public Boolean combinable { get; set; }
        @AuraEnabled public String combinationGroup { get; set; }
        @AuraEnabled public Boolean approvalRequired { get; set; }
        @AuraEnabled public Boolean activateImmediately { get; set; }
    }

    public class CurrencyAmount {
        @AuraEnabled public String currencyIsoCode { get; set; }
        @AuraEnabled public Decimal amount { get; set; }
    }

    public class CreateResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public List<Id> createdRecordIds;
        @AuraEnabled public String status;
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
        String pattern = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        for (Product2 p : [
            SELECT Id, Name, ProductCode
            FROM Product2
            WHERE IsActive = true
            AND (Name LIKE :pattern OR ProductCode LIKE :pattern)
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

        if (input == null) {
            result.success = false;
            result.errorMessage = 'Missing input (no data received).';
            return result;
        }
        List<String> missing = new List<String>();
        if (String.isBlank(input.code)) missing.add('Code');
        if (String.isBlank(input.displayName)) missing.add('Display Name');
        if (String.isBlank(input.discountType)) missing.add('Discount Type');
        if (!missing.isEmpty()) {
            result.success = false;
            result.errorMessage = 'Missing required fields: ' + String.join(missing, ', ');
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

        String statusOnInsert = input.activateImmediately == true ? 'Active' : 'Draft';

        List<Promo_Code__c> toInsert = new List<Promo_Code__c>();
        for (String iso : targetCurrencies) {
            Promo_Code__c rec = new Promo_Code__c(
                Code__c = trimmedCode,
                Discount_Type__c = input.discountType,
                Discount_Value__c = currencyAmountMap.get(iso),
                Status__c = statusOnInsert,
                Effective_Start_Date__c = input.effectiveStart,
                Effective_End_Date__c = input.effectiveEnd,
                Total_Usage_Limit__c = input.totalLimit,
                Per_Member_Usage_Limit__c = input.perMemberLimit,
                Member_Type_Scope__c = (input.memberTypeScope == null || input.memberTypeScope.isEmpty())
                    ? null : String.join(input.memberTypeScope, ';'),
                Region_Scope__c = (input.regionScope == null || input.regionScope.isEmpty())
                    ? null : String.join(input.regionScope, ';'),
                Application_Level__c = String.isBlank(input.applicationLevel) ? 'Per Order' : input.applicationLevel,
                Product_Scope_Type__c = String.isBlank(input.productScopeType) ? 'All Items' : input.productScopeType,
                Product_Family_Scope__c = (input.productFamilyScope == null || input.productFamilyScope.isEmpty())
                    ? null : String.join(input.productFamilyScope, ';'),
                Specific_Products__c = input.specificProducts,
                Account__c = input.accountId,
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
            result.status = statusOnInsert;
            result.createdRecordIds = new List<Id>();
            for (Promo_Code__c r : toInsert) {
                result.createdRecordIds.add(r.Id);
            }
        } catch (DmlException e) {
            Database.rollback(sp);
            result.success = false;
            result.errorMessage = e.getNumDml() > 0 ? e.getDmlMessage(0) : e.getMessage();
        }

        return result;
    }
}
