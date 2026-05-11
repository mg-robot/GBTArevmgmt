import { LightningElement, api, wire, track } from 'lwc';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import COMBINATION_GROUP_FIELD from '@salesforce/schema/Promo_Code__c.Combination_Group__c';

const MASTER_RT = '012000000000000AAA';

/**
 * Step 3 of the wizard. Captures usage limits, combinability, and runtime approval flag.
 * Validity: when Combinable is on, Combination Group must be set (mirrors
 * VR_PromoCode_RequireCombinationGroup on Promo_Code__c).
 */
export default class PromoCodeWizardStepLimits extends LightningElement {
    @api wizardData;

    @track _combinationGroupOptions = [];

    @wire(getPicklistValues, { recordTypeId: MASTER_RT, fieldApiName: COMBINATION_GROUP_FIELD })
    wiredCombGroup({ data }) {
        if (data) this._combinationGroupOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    get combinationGroupOptions() { return this._combinationGroupOptions; }

    connectedCallback() {
        Promise.resolve().then(() => this.fireValidate());
    }

    handleTotalLimitChange(e) {
        const v = e.target.value;
        this.dispatch('totalLimit', v === '' || v == null ? null : parseInt(v, 10));
    }
    handlePerMemberLimitChange(e) {
        const v = e.target.value;
        this.dispatch('perMemberLimit', v === '' || v == null ? null : parseInt(v, 10));
    }
    handleCombinableChange(e) {
        const on = e.target.checked;
        this.dispatch('combinable', on);
        if (!on) this.dispatch('combinationGroup', '');
    }
    handleCombinationGroupChange(e) { this.dispatch('combinationGroup', e.detail.value); }
    handleApprovalRequiredChange(e) { this.dispatch('approvalRequired', e.target.checked); }

    dispatch(field, value) {
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
        Promise.resolve().then(() => this.fireValidate());
    }

    fireValidate() {
        const d = this.wizardData;
        let valid = true;
        if (d?.combinable && !d.combinationGroup) valid = false;
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid } }));
    }
}
