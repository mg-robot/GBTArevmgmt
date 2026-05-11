import { LightningElement, api, wire, track } from 'lwc';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import COMBINATION_GROUP_FIELD from '@salesforce/schema/Promo_Code__c.Combination_Group__c';

import LBL_UsageLimitsHeading from '@salesforce/label/c.PromoCodeWizard_S3_UsageLimits_Heading';
import LBL_UsageLimitsHelper from '@salesforce/label/c.PromoCodeWizard_S3_UsageLimits_Helper';
import LBL_TotalLimit from '@salesforce/label/c.PromoCodeWizard_S3_TotalLimit_Label';
import LBL_PerMemberLimit from '@salesforce/label/c.PromoCodeWizard_S3_PerMemberLimit_Label';
import LBL_UnlimitedPlaceholder from '@salesforce/label/c.PromoCodeWizard_S3_Unlimited_Placeholder';
import LBL_CombinabilityHeading from '@salesforce/label/c.PromoCodeWizard_S3_Combinability_Heading';
import LBL_CombinabilityHelper from '@salesforce/label/c.PromoCodeWizard_S3_Combinability_Helper';
import LBL_Combinable from '@salesforce/label/c.PromoCodeWizard_S3_Combinable_Label';
import LBL_CombinableYes from '@salesforce/label/c.PromoCodeWizard_S3_Combinable_Yes';
import LBL_CombinableNo from '@salesforce/label/c.PromoCodeWizard_S3_Combinable_No';
import LBL_CombinationGroup from '@salesforce/label/c.PromoCodeWizard_S3_CombinationGroup_Label';
import LBL_ApprovalHeading from '@salesforce/label/c.PromoCodeWizard_S3_Approval_Heading';
import LBL_ApprovalHelper from '@salesforce/label/c.PromoCodeWizard_S3_Approval_Helper';
import LBL_ApprovalRequired from '@salesforce/label/c.PromoCodeWizard_S3_ApprovalRequired_Label';

const MASTER_RT = '012000000000000AAA';

/**
 * Step 3 of the wizard. Captures usage limits, combinability, and runtime approval flag.
 * Validity: when Combinable is on, Combination Group must be set.
 */
export default class PromoCodeWizardStepLimits extends LightningElement {
    @api wizardData;

    @track _combinationGroupOptions = [];

    label = {
        usageLimitsHeading: LBL_UsageLimitsHeading,
        usageLimitsHelper: LBL_UsageLimitsHelper,
        totalLimit: LBL_TotalLimit,
        perMemberLimit: LBL_PerMemberLimit,
        unlimitedPlaceholder: LBL_UnlimitedPlaceholder,
        combinabilityHeading: LBL_CombinabilityHeading,
        combinabilityHelper: LBL_CombinabilityHelper,
        combinable: LBL_Combinable,
        combinableYes: LBL_CombinableYes,
        combinableNo: LBL_CombinableNo,
        combinationGroup: LBL_CombinationGroup,
        approvalHeading: LBL_ApprovalHeading,
        approvalHelper: LBL_ApprovalHelper,
        approvalRequired: LBL_ApprovalRequired
    };

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
