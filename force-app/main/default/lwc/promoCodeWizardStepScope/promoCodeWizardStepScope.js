import { LightningElement, api, wire, track } from 'lwc';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';

import MEMBER_TYPE_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Member_Type_Scope__c';
import REGION_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Region_Scope__c';
import PRODUCT_SCOPE_TYPE_FIELD from '@salesforce/schema/Promo_Code__c.Product_Scope_Type__c';
import PRODUCT_FAMILY_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Product_Family_Scope__c';
import APPLICATION_LEVEL_FIELD from '@salesforce/schema/Promo_Code__c.Application_Level__c';

import LBL_ValidityHeading from '@salesforce/label/c.PromoCodeWizard_S2_Validity_Heading';
import LBL_EffectiveStart from '@salesforce/label/c.PromoCodeWizard_S2_EffectiveStart_Label';
import LBL_EffectiveEnd from '@salesforce/label/c.PromoCodeWizard_S2_EffectiveEnd_Label';
import LBL_MemberTypeScope from '@salesforce/label/c.PromoCodeWizard_S2_MemberType_Label';
import LBL_RegionScope from '@salesforce/label/c.PromoCodeWizard_S2_Region_Label';
import LBL_ProductAppHeading from '@salesforce/label/c.PromoCodeWizard_S2_ProductApp_Heading';
import LBL_ProductScope from '@salesforce/label/c.PromoCodeWizard_S2_ProductScope_Label';
import LBL_ProductFamily from '@salesforce/label/c.PromoCodeWizard_S2_ProductFamily_Label';
import LBL_AccountScopeHeading from '@salesforce/label/c.PromoCodeWizard_S2_AccountScope_Heading';
import LBL_AccountScopeHelper from '@salesforce/label/c.PromoCodeWizard_S2_AccountScope_Helper';
import LBL_Account from '@salesforce/label/c.PromoCodeWizard_S2_Account_Label';

const MASTER_RT = '012000000000000AAA';

// Helper micro-copy verbatim from creation-wizard.md §2 Step 2.
const VALIDITY_HELPER =
    "Set when this code is valid. After the end date passes, members will see an 'this code is not valid right now' message at checkout — the code stays Active in the system but won't apply.";
const REGION_APP_LEVEL_HELPER =
    'Leave Region Scope blank to make this code available in all regions. Application Level controls how the promo value is applied: Per Order distributes the value proportionately across the eligible lines; Per Line applies the full value to each eligible line.';
const PRODUCT_APP_HELPER =
    'Choose what this code discounts. Eligible lines combine with the Application Level to determine the final per-line adjustment.';
const ALL_ITEMS_MESSAGE = 'All lines in the order are eligible.';

// Combination-specific helper text, keyed by `${applicationLevel}|${productScopeType}`.
const COMBINATION_HELP = {
    'Per Order|All Items':
        'The promo value will be divided proportionately across all lines in the order.',
    'Per Order|Product Family':
        'The promo value will be divided proportionately across lines matching the selected family/families.',
    'Per Order|Specific Membership Types':
        'The promo value will be divided proportionately across lines whose Product Name contains any of the selected membership types (case-insensitive).',
    'Per Order|Specific Products':
        'The promo value will be divided proportionately across the selected products that appear in the order.',
    'Per Line|All Items':
        'The full promo value will be applied to every line in the order. (e.g., a $20 promo on a cart with 3 lines = $60 total discount.)',
    'Per Line|Product Family':
        'The full promo value will be applied to each line matching the selected family/families.',
    'Per Line|Specific Membership Types':
        'The full promo value will be applied to each line whose Product Name contains any of the selected membership types.',
    'Per Line|Specific Products':
        'The full promo value will be applied to each of the selected products in the order.'
};

/**
 * Step 2 of the wizard — Scope & Eligibility.
 * Four sections per creation-wizard.md §2:
 *   1. Validity Window (two-column dates)
 *   2. Region & Application Level (two-column)
 *   3. Product Applicability (two-column: scope-type radio + conditional sub-control)
 *   4. Account Scope
 */
export default class PromoCodeWizardStepScope extends LightningElement {
    @api wizardData;

    @track _memberTypeOptions = [];
    @track _regionOptions = [];
    @track _productScopeTypeOptions = [];
    @track _productFamilyOptions = [];
    @track _applicationLevelOptions = [];

    label = {
        validityHeading: LBL_ValidityHeading,
        validityHelper: VALIDITY_HELPER,
        effectiveStart: LBL_EffectiveStart,
        effectiveEnd: LBL_EffectiveEnd,
        regionAppLevelHeading: 'Region & Application Level',
        regionAppLevelHelper: REGION_APP_LEVEL_HELPER,
        applicationLevelLabel: 'Application Level',
        memberTypeScope: LBL_MemberTypeScope,
        regionScope: LBL_RegionScope,
        productAppHeading: LBL_ProductAppHeading,
        productAppHelper: PRODUCT_APP_HELPER,
        productScope: LBL_ProductScope,
        productFamily: LBL_ProductFamily,
        allItemsMessage: ALL_ITEMS_MESSAGE,
        accountScopeHeading: LBL_AccountScopeHeading,
        accountScopeHelper: LBL_AccountScopeHelper,
        account: LBL_Account
    };

    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: MEMBER_TYPE_SCOPE_FIELD })
    wiredMemberType({ data }) {
        if (data) this._memberTypeOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }
    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: REGION_SCOPE_FIELD })
    wiredRegion({ data }) {
        if (data) this._regionOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }
    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: PRODUCT_SCOPE_TYPE_FIELD })
    wiredProductScopeType({ data }) {
        if (data) this._productScopeTypeOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }
    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: PRODUCT_FAMILY_SCOPE_FIELD })
    wiredProductFamily({ data }) {
        if (data) this._productFamilyOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }
    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: APPLICATION_LEVEL_FIELD })
    wiredApplicationLevel({ data }) {
        if (data) this._applicationLevelOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    get memberTypeOptions() { return this._memberTypeOptions; }
    get regionOptions() { return this._regionOptions; }
    get productScopeTypeOptions() { return this._productScopeTypeOptions; }
    get productFamilyOptions() { return this._productFamilyOptions; }
    get applicationLevelOptions() { return this._applicationLevelOptions; }

    get isAllItems() { return this.wizardData?.productScopeType === 'All Items'; }
    get isProductFamily() { return this.wizardData?.productScopeType === 'Product Family'; }
    get isSpecificMembershipTypes() { return this.wizardData?.productScopeType === 'Specific Membership Types'; }
    get isSpecificProducts() { return this.wizardData?.productScopeType === 'Specific Products'; }

    get combinationHelpText() {
        const key = `${this.wizardData?.applicationLevel || 'Per Order'}|${this.wizardData?.productScopeType || 'All Items'}`;
        return COMBINATION_HELP[key] || '';
    }

    connectedCallback() {
        Promise.resolve().then(() => this.fireValidate());
    }

    handleStartChange(e) { this.dispatch('effectiveStart', e.target.value); }
    handleEndChange(e) { this.dispatch('effectiveEnd', e.target.value); }
    handleRegionScopeChange(e) { this.dispatch('regionScope', e.detail.value); }

    handleApplicationLevelChange(e) {
        const v = e.detail.value;
        this.dispatch('applicationLevel', v);
        // Suggest All Items default when switching to Per Order (don't force — staff can override)
        if (v === 'Per Order' && !this.wizardData?.productScopeType) {
            this.dispatch('productScopeType', 'All Items');
        }
    }

    handleProductScopeTypeChange(e) {
        const v = e.detail.value;
        const prev = this.wizardData?.productScopeType;
        this.dispatch('productScopeType', v);
        // Clear stale sub-control values to avoid leaking previous selections into the save payload
        if (prev && prev !== v) {
            if (prev === 'Product Family') this.dispatch('productFamilyScope', []);
            if (prev === 'Specific Membership Types') this.dispatch('memberTypeScope', []);
            if (prev === 'Specific Products') this.dispatch('specificProducts', '');
        }
    }

    handleProductFamilyScopeChange(e) { this.dispatch('productFamilyScope', e.detail.value); }
    handleMemberTypeScopeChange(e) { this.dispatch('memberTypeScope', e.detail.value); }
    handleSpecificProductsChange(e) { this.dispatch('specificProducts', e.detail.csv); }
    handleAccountChange(e) { this.dispatch('accountId', e.detail.recordId || null); }

    dispatch(field, value) {
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
        Promise.resolve().then(() => this.fireValidate());
    }

    fireValidate() {
        const d = this.wizardData || {};
        let valid = true;
        // Validity Window: end must be after start when both set
        if (d.effectiveStart && d.effectiveEnd) {
            if (new Date(d.effectiveEnd) <= new Date(d.effectiveStart)) valid = false;
        }
        // Required fields
        if (!d.applicationLevel) valid = false;
        if (!d.productScopeType) valid = false;
        // Conditional sub-control populated when scope != All Items
        if (d.productScopeType === 'Product Family' && (!d.productFamilyScope || d.productFamilyScope.length === 0)) valid = false;
        if (d.productScopeType === 'Specific Membership Types' && (!d.memberTypeScope || d.memberTypeScope.length === 0)) valid = false;
        if (d.productScopeType === 'Specific Products' && !d.specificProducts) valid = false;
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid } }));
    }
}
