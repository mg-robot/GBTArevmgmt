import { LightningElement, api, wire, track } from 'lwc';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';

import MEMBER_TYPE_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Member_Type_Scope__c';
import REGION_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Region_Scope__c';
import PRODUCT_SCOPE_TYPE_FIELD from '@salesforce/schema/Promo_Code__c.Product_Scope_Type__c';

const MASTER_RT = '012000000000000AAA';
const PRODUCT_FAMILY_VALUES = [
    { label: 'Membership', value: 'Membership' },
    { label: 'Chapter', value: 'Chapter' },
    { label: 'Section', value: 'Section' }
];

/**
 * Step 2 of the wizard. Captures effective window, member type & region scope,
 * product applicability, and optional Account scope. Always passes validation
 * (every field is optional).
 */
export default class PromoCodeWizardStepScope extends LightningElement {
    @api wizardData;

    @track _memberTypeOptions = [];
    @track _regionOptions = [];
    @track _productScopeTypeOptions = [];

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

    get memberTypeOptions() { return this._memberTypeOptions; }
    get regionOptions() { return this._regionOptions; }
    get productScopeTypeOptions() { return this._productScopeTypeOptions; }
    get productFamilyOptions() { return PRODUCT_FAMILY_VALUES; }

    get isProductFamily() { return this.wizardData?.productScopeType === 'Product Family'; }
    get isSpecificProducts() { return this.wizardData?.productScopeType === 'Specific Products'; }

    connectedCallback() {
        Promise.resolve().then(() => this.fireValidate());
    }

    handleStartChange(e) { this.dispatch('effectiveStart', e.target.value); }
    handleEndChange(e) { this.dispatch('effectiveEnd', e.target.value); }
    handleMemberTypeScopeChange(e) { this.dispatch('memberTypeScope', e.detail.value); }
    handleRegionScopeChange(e) { this.dispatch('regionScope', e.detail.value); }
    handleProductScopeTypeChange(e) {
        const v = e.detail.value;
        this.dispatch('productScopeType', v);
        if (v === 'All Items') {
            this.dispatch('specificProducts', '');
        }
    }
    handleProductFamilyChange(e) { this.dispatch('specificProducts', e.detail.value); }
    handleSpecificProductsChange(e) { this.dispatch('specificProducts', e.detail.csv); }
    handleAccountChange(e) { this.dispatch('accountId', e.detail.recordId || null); }

    dispatch(field, value) {
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
        Promise.resolve().then(() => this.fireValidate());
    }

    fireValidate() {
        const d = this.wizardData;
        let valid = true;
        if (d?.effectiveStart && d?.effectiveEnd) {
            if (new Date(d.effectiveEnd) <= new Date(d.effectiveStart)) valid = false;
        }
        if (d?.productScopeType === 'Product Family' && !d.specificProducts) valid = false;
        if (d?.productScopeType === 'Specific Products' && !d.specificProducts) valid = false;
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid } }));
    }
}
