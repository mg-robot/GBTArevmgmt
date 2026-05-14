/**
 * Apex service backing the Promo Code creation wizard (Membership Ops staff path).
 *
 * Responsibilities:
 * - getActiveCurrencies(): active CurrencyType ISO codes for the wizard currency picker.
 * - checkCodeUniqueness(code): which currencies (if any) already use a given code; used by the
 *   wizard for real-time feedback as the user types.
 * - searchProducts(searchTerm): Product2 typeahead for the Specific Products picker (matches on
 *   Name or ProductCode). The picker persists Product2.ProductCode (CSV) onto
 *   Specific_Products__c — aligned with PromoCodeAllocationEngine's case-insensitive ProductCode
 *   match. See docs/promo-code/checkout-apply-flow.md §5.2.
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
    @AuraEnabled
    public String code { get; set; }
    @AuraEnabled
    public String displayName { get; set; }
    @AuraEnabled
    public String terms { get; set; }
    @AuraEnabled
    public String discountType { get; set; }
    @AuraEnabled
    public Decimal percentValue { get; set; }
    @AuraEnabled
    public List<String> percentCurrencies { get; set; }
    @AuraEnabled
    public List<CurrencyAmount> amounts { get; set; }
    @AuraEnabled
    public Datetime effectiveStart { get; set; }
    @AuraEnabled
    public Datetime effectiveEnd { get; set; }
    @AuraEnabled
    public Decimal totalLimit { get; set; }
    @AuraEnabled
    public Decimal perMemberLimit { get; set; }
    @AuraEnabled
    public List<String> memberTypeScope { get; set; }
    @AuraEnabled
    public List<String> regionScope { get; set; }
    @AuraEnabled
    public String applicationLevel { get; set; }
    @AuraEnabled
    public String productScopeType { get; set; }
    @AuraEnabled
    public List<String> productFamilyScope { get; set; }
    @AuraEnabled
    public String specificProducts { get; set; }
    @AuraEnabled
    public Id accountId { get; set; }
    @AuraEnabled
    public Boolean combinable { get; set; }
    @AuraEnabled
    public String combinationGroup { get; set; }
    @AuraEnabled
    public Boolean approvalRequired { get; set; }
    @AuraEnabled
    public Boolean activateImmediately { get; set; }
  }

  public class CurrencyAmount {
    @AuraEnabled
    public String currencyIsoCode { get; set; }
    @AuraEnabled
    public Decimal amount { get; set; }
  }

  public class CreateResult {
    @AuraEnabled
    public Boolean success;
    @AuraEnabled
    public List<Id> createdRecordIds;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String errorMessage;
    @AuraEnabled
    public List<String> conflictCurrencies;
  }

  public class ProductOption {
    @AuraEnabled
    public Id id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String productCode;
  }

  @AuraEnabled(cacheable=true)
  public static List<String> getActiveCurrencies() {
    List<String> currencies = new List<String>();
    if (Schema.getGlobalDescribe().containsKey('CurrencyType')) {
      for (
        SObject ct : Database.query(
          'SELECT IsoCode FROM CurrencyType WHERE IsActive = true ORDER BY IsoCode'
        )
      ) {
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
    Boolean isMultiCurrency =
      Schema.getGlobalDescribe().containsKey('CurrencyType') &&
      Schema.SObjectType.Promo_Code__c.fields.getMap()
        .containsKey('currencyisocode');
    String soql =
      'SELECT ' +
      (isMultiCurrency ? 'CurrencyIsoCode' : 'Id') +
      ' FROM Promo_Code__c WHERE Code__c = :trimmed';
    for (SObject pc : Database.query(soql)) {
      conflicts.add(
        isMultiCurrency ? (String) pc.get('CurrencyIsoCode') : 'DEFAULT'
      );
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
      WHERE
        IsActive = TRUE
        AND (Name LIKE :pattern
        OR ProductCode LIKE :pattern)
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
    if (String.isBlank(input.code))
      missing.add('Code');
    if (String.isBlank(input.displayName))
      missing.add('Display Name');
    if (String.isBlank(input.discountType))
      missing.add('Discount Type');
    if (!missing.isEmpty()) {
      result.success = false;
      result.errorMessage =
        'Missing required fields: ' + String.join(missing, ', ');
      return result;
    }

    Boolean isMultiCurrency =
      Schema.getGlobalDescribe().containsKey('CurrencyType') &&
      Schema.SObjectType.Promo_Code__c.fields.getMap()
        .containsKey('currencyisocode');

    Map<String, Decimal> currencyAmountMap = new Map<String, Decimal>();
    if ('Percent'.equalsIgnoreCase(input.discountType)) {
      if (
        input.percentValue == null ||
        input.percentValue <= 0 ||
        input.percentValue > 100
      ) {
        result.success = false;
        result.errorMessage = 'Percent value must be between 0 and 100.';
        return result;
      }
      List<String> isos = (input.percentCurrencies == null ||
        input.percentCurrencies.isEmpty())
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
        if (
          String.isBlank(ca.currencyIsoCode) ||
          ca.amount == null ||
          ca.amount <= 0
        ) {
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

    List<String> targetCurrencies = new List<String>(
      currencyAmountMap.keySet()
    );
    String trimmedCode = input.code.trim();

    if (isMultiCurrency) {
      String soql =
        'SELECT CurrencyIsoCode FROM Promo_Code__c ' +
        'WHERE Code__c = :trimmedCode AND CurrencyIsoCode IN :targetCurrencies';
      List<SObject> existing = Database.query(soql);
      if (!existing.isEmpty()) {
        result.success = false;
        result.conflictCurrencies = new List<String>();
        for (SObject pc : existing) {
          result.conflictCurrencies.add((String) pc.get('CurrencyIsoCode'));
        }
        result.errorMessage =
          'Code "' +
          trimmedCode +
          '" already exists for: ' +
          String.join(result.conflictCurrencies, ', ');
        return result;
      }
    }

    String statusOnInsert = input.activateImmediately == true
      ? 'Active'
      : 'Draft';

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
        Member_Type_Scope__c = (input.memberTypeScope == null ||
          input.memberTypeScope.isEmpty())
          ? null
          : String.join(input.memberTypeScope, ';'),
        Region_Scope__c = (input.regionScope == null ||
          input.regionScope.isEmpty())
          ? null
          : String.join(input.regionScope, ';'),
        Application_Level__c = String.isBlank(input.applicationLevel)
          ? 'Per Order'
          : input.applicationLevel,
        Product_Scope_Type__c = String.isBlank(input.productScopeType)
          ? 'All Items'
          : input.productScopeType,
        Product_Family_Scope__c = (input.productFamilyScope == null ||
          input.productFamilyScope.isEmpty())
          ? null
          : String.join(input.productFamilyScope, ';'),
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
      result.errorMessage = e.getNumDml() > 0
        ? e.getDmlMessage(0)
        : e.getMessage();
    }

    return result;
  }

  // ===================================================================================
  // Load + Activate existing — supports the "Open in Setup Wizard" Quick Action on a
  // Promo_Code__c record. The wizard lands on the Review step pre-filled with the
  // record's values (plus any currency siblings sharing the same Code__c), and the user
  // can Activate Now to flip Draft -> Active across the whole batch.
  // ===================================================================================

  public class LoadedDefinition {
    @AuraEnabled
    public PromoCodeInput input;
    @AuraEnabled
    public List<Id> sourceRecordIds;
    @AuraEnabled
    public String currentStatus; // status of the source record
    @AuraEnabled
    public Boolean allDraft; // true iff every sibling is in Draft
  }

  public class ActivationResult {
    @AuraEnabled
    public Boolean success;
    @AuraEnabled
    public Integer activatedCount;
    @AuraEnabled
    public Integer skippedCount; // already-Active records that needed no change
    @AuraEnabled
    public String errorMessage;
  }

  /**
   * Lightweight status fetch used by the Open in Setup Wizard quick action to gate
   * the modal entirely when the record is already Active — avoids loading the full
   * definition just to discover we can't edit it. Returns null if the record can't
   * be found / accessed.
   */
  @AuraEnabled(cacheable=true)
  public static String getRecordStatus(Id recordId) {
    if (recordId == null) {
      return null;
    }
    List<Promo_Code__c> rs = [
      SELECT Status__c
      FROM Promo_Code__c
      WHERE Id = :recordId
      LIMIT 1
    ];
    return rs.isEmpty() ? null : rs[0].Status__c;
  }

  @AuraEnabled
  public static LoadedDefinition loadDefinition(Id recordId) {
    if (recordId == null) {
      throw new AuraHandledException('Missing recordId.');
    }
    Promo_Code__c source;
    try {
      source = [
        SELECT
          Id,
          Code__c,
          Display_Name__c,
          Terms__c,
          Status__c,
          Discount_Type__c,
          Discount_Value__c,
          Effective_Start_Date__c,
          Effective_End_Date__c,
          Total_Usage_Limit__c,
          Per_Member_Usage_Limit__c,
          Member_Type_Scope__c,
          Region_Scope__c,
          Application_Level__c,
          Product_Scope_Type__c,
          Product_Family_Scope__c,
          Specific_Products__c,
          Account__c,
          Combinable__c,
          Combination_Group__c,
          Approval_Required__c
        FROM Promo_Code__c
        WHERE Id = :recordId
        LIMIT 1
      ];
    } catch (QueryException qe) {
      throw new AuraHandledException('Promo Code not found or not accessible.');
    }

    Boolean isMultiCurrency = Schema.SObjectType.Promo_Code__c.fields.getMap()
      .containsKey('currencyisocode');

    // Pull all currency siblings sharing the same Code__c so the wizard can present
    // the full multi-currency definition (matches the create-wizard's batch shape).
    String soql =
      'SELECT Id, Discount_Value__c' +
      (isMultiCurrency ? ', CurrencyIsoCode' : '') +
      ' FROM Promo_Code__c WHERE Code__c = :sourceCode ORDER BY Id';
    String sourceCode = source.Code__c;
    List<SObject> siblings = Database.query(soql);

    LoadedDefinition out = new LoadedDefinition();
    out.sourceRecordIds = new List<Id>();
    out.currentStatus = source.Status__c;
    out.allDraft = true;

    PromoCodeInput inp = new PromoCodeInput();
    inp.code = source.Code__c;
    inp.displayName = source.Display_Name__c;
    inp.terms = source.Terms__c;
    inp.discountType = source.Discount_Type__c;
    inp.effectiveStart = source.Effective_Start_Date__c;
    inp.effectiveEnd = source.Effective_End_Date__c;
    inp.totalLimit = source.Total_Usage_Limit__c;
    inp.perMemberLimit = source.Per_Member_Usage_Limit__c;
    inp.memberTypeScope = splitMulti(source.Member_Type_Scope__c);
    inp.regionScope = splitMulti(source.Region_Scope__c);
    inp.applicationLevel = source.Application_Level__c;
    inp.productScopeType = source.Product_Scope_Type__c;
    inp.productFamilyScope = splitMulti(source.Product_Family_Scope__c);
    inp.specificProducts = source.Specific_Products__c;
    inp.accountId = source.Account__c;
    inp.combinable = source.Combinable__c;
    inp.combinationGroup = source.Combination_Group__c;
    inp.approvalRequired = source.Approval_Required__c;
    inp.activateImmediately = false; // unused on this code path; activateBulk handles it

    // Re-status check across all siblings to set allDraft correctly. The wizard uses
    // this to decide whether Activate Now is meaningful (already-Active = no-op label).
    Set<Id> siblingIds = new Set<Id>();
    for (SObject sib : siblings) {
      siblingIds.add((Id) sib.get('Id'));
    }
    if (!siblingIds.isEmpty()) {
      for (Promo_Code__c pc : [
        SELECT Id, Status__c
        FROM Promo_Code__c
        WHERE Id IN :siblingIds
      ]) {
        if (pc.Status__c != 'Draft')
          out.allDraft = false;
      }
    }

    // Build per-currency rows for the Review screen.
    if ('Amount'.equalsIgnoreCase(source.Discount_Type__c)) {
      inp.amounts = new List<CurrencyAmount>();
      for (SObject sib : siblings) {
        CurrencyAmount ca = new CurrencyAmount();
        ca.currencyIsoCode = isMultiCurrency
          ? (String) sib.get('CurrencyIsoCode')
          : UserInfo.getDefaultCurrency();
        ca.amount = (Decimal) sib.get('Discount_Value__c');
        inp.amounts.add(ca);
        out.sourceRecordIds.add((Id) sib.get('Id'));
      }
    } else {
      // Percent codes share the same Discount_Value__c across all per-currency rows.
      inp.percentValue = source.Discount_Value__c;
      inp.percentCurrencies = new List<String>();
      for (SObject sib : siblings) {
        if (isMultiCurrency) {
          inp.percentCurrencies.add((String) sib.get('CurrencyIsoCode'));
        }
        out.sourceRecordIds.add((Id) sib.get('Id'));
      }
      if (!isMultiCurrency) {
        inp.percentCurrencies.add(UserInfo.getDefaultCurrency());
      }
    }

    out.input = inp;
    return out;
  }

  /**
   * Updates an existing batch of Promo_Code__c records (sharing the same Code value)
   * driven by the wizard's edit mode (Open in Setup Wizard quick action).
   *
   * Strategy:
   *  - Compare the incoming currency set against the existing per-currency siblings.
   *    For each currency in the new set: update the matching sibling if one exists,
   *    otherwise insert a fresh per-currency record. Currencies present today but
   *    absent in the new set are deleted (master-detail cascades children — Drafts
   *    have no Promo_Code_Item__c children to begin with).
   *  - Refuses if any sibling is already Active. Active records are governed by
   *    VR_PromoCode_Lock_After_Create; edits to Active codes still require the
   *    Bypass_Promo_Code_Lock permission and the manual record edit path.
   *  - Composite-uniqueness pre-check excludes the records we own (Id NOT IN), so a
   *    no-op save isn't reported as a self-conflict.
   *  - When activate=true the entire batch (updated + inserted) flips to Active in the
   *    same transaction. The Draft -> Active transition is allowed by the lock VR
   *    because the prior Status was Draft.
   */
  @AuraEnabled
  public static CreateResult updateBulk(
    PromoCodeInput input,
    List<Id> recordIds,
    Boolean activate
  ) {
    CreateResult result = new CreateResult();

    if (input == null) {
      result.success = false;
      result.errorMessage = 'Missing input (no data received).';
      return result;
    }
    if (recordIds == null || recordIds.isEmpty()) {
      result.success = false;
      result.errorMessage = 'No source records supplied to update.';
      return result;
    }

    List<String> missing = new List<String>();
    if (String.isBlank(input.code))
      missing.add('Code');
    if (String.isBlank(input.displayName))
      missing.add('Display Name');
    if (String.isBlank(input.discountType))
      missing.add('Discount Type');
    if (!missing.isEmpty()) {
      result.success = false;
      result.errorMessage =
        'Missing required fields: ' + String.join(missing, ', ');
      return result;
    }

    Boolean isMultiCurrency =
      Schema.getGlobalDescribe().containsKey('CurrencyType') &&
      Schema.SObjectType.Promo_Code__c.fields.getMap()
        .containsKey('currencyisocode');

    Map<String, Decimal> currencyAmountMap = new Map<String, Decimal>();
    if ('Percent'.equalsIgnoreCase(input.discountType)) {
      if (
        input.percentValue == null ||
        input.percentValue <= 0 ||
        input.percentValue > 100
      ) {
        result.success = false;
        result.errorMessage = 'Percent value must be between 0 and 100.';
        return result;
      }
      List<String> isos = (input.percentCurrencies == null ||
        input.percentCurrencies.isEmpty())
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
        if (
          String.isBlank(ca.currencyIsoCode) ||
          ca.amount == null ||
          ca.amount <= 0
        ) {
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

    Set<Id> recordIdSet = new Set<Id>(recordIds);
    String trimmedCode = input.code.trim();

    // Load existing per-currency siblings the wizard owns.
    String existingSoql =
      'SELECT Id, Status__c' +
      (isMultiCurrency ? ', CurrencyIsoCode' : '') +
      ' FROM Promo_Code__c WHERE Id IN :recordIdSet';
    List<SObject> existing = Database.query(existingSoql);
    if (existing.isEmpty()) {
      result.success = false;
      result.errorMessage = 'No matching promo code records found.';
      return result;
    }

    // Active records are off-limits via this path. The quick action is meant for
    // Draft modifications; the VR + Bypass permission govern Active-code edits.
    for (SObject sob : existing) {
      if ('Active'.equals((String) sob.get('Status__c'))) {
        result.success = false;
        result.errorMessage = 'Cannot edit an Active promo code through the wizard. Only Draft codes can be modified here.';
        return result;
      }
    }

    Map<String, Id> existingByCurrency = new Map<String, Id>();
    for (SObject sob : existing) {
      String iso = isMultiCurrency
        ? (String) sob.get('CurrencyIsoCode')
        : 'DEFAULT';
      existingByCurrency.put(iso, (Id) sob.get('Id'));
    }

    // Composite-uniqueness pre-check that excludes the records we already own.
    if (isMultiCurrency) {
      List<String> targetCurrencyList = new List<String>(
        currencyAmountMap.keySet()
      );
      String conflictSoql =
        'SELECT CurrencyIsoCode FROM Promo_Code__c ' +
        'WHERE Code__c = :trimmedCode ' +
        'AND CurrencyIsoCode IN :targetCurrencyList ' +
        'AND Id NOT IN :recordIdSet';
      List<SObject> conflicts = Database.query(conflictSoql);
      if (!conflicts.isEmpty()) {
        result.success = false;
        result.conflictCurrencies = new List<String>();
        for (SObject c : conflicts) {
          result.conflictCurrencies.add((String) c.get('CurrencyIsoCode'));
        }
        result.errorMessage =
          'Code "' +
          trimmedCode +
          '" already exists for: ' +
          String.join(result.conflictCurrencies, ', ');
        return result;
      }
    }

    String statusOnSave = activate == true ? 'Active' : 'Draft';

    List<Promo_Code__c> toUpdate = new List<Promo_Code__c>();
    List<Promo_Code__c> toInsert = new List<Promo_Code__c>();
    List<Id> toDeleteIds = new List<Id>();

    for (String iso : currencyAmountMap.keySet()) {
      Promo_Code__c rec = new Promo_Code__c(
        Code__c = trimmedCode,
        Discount_Type__c = input.discountType,
        Discount_Value__c = currencyAmountMap.get(iso),
        Status__c = statusOnSave,
        Effective_Start_Date__c = input.effectiveStart,
        Effective_End_Date__c = input.effectiveEnd,
        Total_Usage_Limit__c = input.totalLimit,
        Per_Member_Usage_Limit__c = input.perMemberLimit,
        Member_Type_Scope__c = (input.memberTypeScope == null ||
          input.memberTypeScope.isEmpty())
          ? null
          : String.join(input.memberTypeScope, ';'),
        Region_Scope__c = (input.regionScope == null ||
          input.regionScope.isEmpty())
          ? null
          : String.join(input.regionScope, ';'),
        Application_Level__c = String.isBlank(input.applicationLevel)
          ? 'Per Order'
          : input.applicationLevel,
        Product_Scope_Type__c = String.isBlank(input.productScopeType)
          ? 'All Items'
          : input.productScopeType,
        Product_Family_Scope__c = (input.productFamilyScope == null ||
          input.productFamilyScope.isEmpty())
          ? null
          : String.join(input.productFamilyScope, ';'),
        Specific_Products__c = input.specificProducts,
        Account__c = input.accountId,
        Combinable__c = input.combinable == true,
        Combination_Group__c = input.combinationGroup,
        Display_Name__c = input.displayName,
        Terms__c = input.terms,
        Approval_Required__c = input.approvalRequired == true
      );
      if (existingByCurrency.containsKey(iso)) {
        rec.Id = existingByCurrency.get(iso);
        toUpdate.add(rec);
      } else {
        if (isMultiCurrency) {
          rec.put('CurrencyIsoCode', iso);
        }
        toInsert.add(rec);
      }
    }

    for (String existingIso : existingByCurrency.keySet()) {
      if (!currencyAmountMap.containsKey(existingIso)) {
        toDeleteIds.add(existingByCurrency.get(existingIso));
      }
    }

    Savepoint sp = Database.setSavepoint();
    try {
      if (!toDeleteIds.isEmpty()) {
        List<Promo_Code__c> toDelete = new List<Promo_Code__c>();
        for (Id delId : toDeleteIds) {
          toDelete.add(new Promo_Code__c(Id = delId));
        }
        delete toDelete;
      }
      if (!toUpdate.isEmpty()) {
        update toUpdate;
      }
      if (!toInsert.isEmpty()) {
        insert toInsert;
      }
      result.success = true;
      result.status = statusOnSave;
      result.createdRecordIds = new List<Id>();
      for (Promo_Code__c r : toUpdate) {
        result.createdRecordIds.add(r.Id);
      }
      for (Promo_Code__c r : toInsert) {
        result.createdRecordIds.add(r.Id);
      }
    } catch (DmlException e) {
      Database.rollback(sp);
      result.success = false;
      result.errorMessage = e.getNumDml() > 0
        ? e.getDmlMessage(0)
        : e.getMessage();
    }

    return result;
  }

  @AuraEnabled
  public static ActivationResult activateBulk(List<Id> recordIds) {
    ActivationResult res = new ActivationResult();
    res.activatedCount = 0;
    res.skippedCount = 0;
    if (recordIds == null || recordIds.isEmpty()) {
      res.success = false;
      res.errorMessage = 'No records supplied.';
      return res;
    }

    List<Promo_Code__c> toUpdate = new List<Promo_Code__c>();
    for (Promo_Code__c pc : [
      SELECT Id, Status__c
      FROM Promo_Code__c
      WHERE Id IN :recordIds
    ]) {
      if (pc.Status__c == 'Active') {
        res.skippedCount += 1;
        continue;
      }
      toUpdate.add(new Promo_Code__c(Id = pc.Id, Status__c = 'Active'));
    }

    if (toUpdate.isEmpty()) {
      res.success = true; // nothing to do; not an error
      return res;
    }

    try {
      update toUpdate;
      res.success = true;
      res.activatedCount = toUpdate.size();
    } catch (DmlException e) {
      res.success = false;
      res.errorMessage = e.getNumDml() > 0
        ? e.getDmlMessage(0)
        : e.getMessage();
    }
    return res;
  }

  private static List<String> splitMulti(String csv) {
    if (String.isBlank(csv))
      return new List<String>();
    List<String> out = new List<String>();
    for (String s : csv.split(';')) {
      String t = s.trim();
      if (String.isNotBlank(t))
        out.add(t);
    }
    return out;
  }
}
