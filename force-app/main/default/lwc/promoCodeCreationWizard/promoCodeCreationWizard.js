import { LightningElement, api, wire, track } from 'lwc';
import { CloseActionScreenEvent } from 'lightning/actions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';

import getActiveCurrencies from '@salesforce/apex/PromoCodeService.getActiveCurrencies';
import checkCodeUniqueness from '@salesforce/apex/PromoCodeService.checkCodeUniqueness';
import createBulk from '@salesforce/apex/PromoCodeService.createBulk';

import MEMBER_TYPE_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Member_Type_Scope__c';
import REGION_SCOPE_FIELD from '@salesforce/schema/Promo_Code__c.Region_Scope__c';
import PRODUCT_SCOPE_TYPE_FIELD from '@salesforce/schema/Promo_Code__c.Product_Scope_Type__c';
import COMBINATION_GROUP_FIELD from '@salesforce/schema/Promo_Code__c.Combination_Group__c';

const TOTAL_STEPS = 9;
const MASTER_RECORD_TYPE_ID = '012000000000000AAA';

const STEP_TITLES = {
    1: 'Identity',
    2: 'Discount Type',
    3: 'Discount Value',
    4: 'Validity Window',
    5: 'Usage Limits',
    6: 'Applicability',
    7: 'Combinability',
    8: 'Approval',
    9: 'Review & Confirm'
};

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' }
];

const PRODUCT_FAMILY_VALUES = [
    { label: 'Membership', value: 'Membership' },
    { label: 'Chapter', value: 'Chapter' },
    { label: 'Section', value: 'Section' }
];

export default class PromoCodeCreationWizard extends NavigationMixin(LightningElement) {
    @api recordId;
    @api objectApiName;

    currentStep = 1;
    errorMessage = '';
    isSubmitting = false;

    code = '';
    displayName = '';
    terms = '';
    discountType = '';
    percentValue = null;
    selectedPercentCurrencies = [];
    amounts = [];
    effectiveStart = '';
    effectiveEnd = '';
    totalLimit = null;
    perMemberLimit = null;
    memberTypeScope = [];
    regionScope = [];
    productScopeType = 'All Items';
    specificProducts = '';
    accountId = null;
    combinable = true;
    combinationGroup = 'General';
    approvalRequired = false;

    availableCurrencies = [];
    codeConflicts = null;

    @track _memberTypeOptions = [];
    @track _regionOptions = [];
    @track _productScopeTypeOptions = [];
    @track _combinationGroupOptions = [];

    @wire(getActiveCurrencies)
    wiredCurrencies({ data }) {
        if (data) {
            this.availableCurrencies = data;
            if (this.selectedPercentCurrencies.length === 0) {
                this.selectedPercentCurrencies = [...data];
            }
        }
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE_ID, fieldApiName: MEMBER_TYPE_SCOPE_FIELD })
    wiredMemberType({ data }) {
        if (data) this._memberTypeOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE_ID, fieldApiName: REGION_SCOPE_FIELD })
    wiredRegion({ data }) {
        if (data) this._regionOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE_ID, fieldApiName: PRODUCT_SCOPE_TYPE_FIELD })
    wiredProductScopeType({ data }) {
        if (data) this._productScopeTypeOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    @wire(getPicklistValues, { recordTypeId: MASTER_RECORD_TYPE_ID, fieldApiName: COMBINATION_GROUP_FIELD })
    wiredCombinationGroup({ data }) {
        if (data) this._combinationGroupOptions = data.values.map((v) => ({ label: v.label, value: v.value }));
    }

    get stepTitle() {
        return STEP_TITLES[this.currentStep] || '';
    }
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isStep5() { return this.currentStep === 5; }
    get isStep6() { return this.currentStep === 6; }
    get isStep7() { return this.currentStep === 7; }
    get isStep8() { return this.currentStep === 8; }
    get isStep9() { return this.currentStep === 9; }
    get isLastStep() { return this.currentStep === TOTAL_STEPS; }
    get canGoBack() { return this.currentStep > 1; }

    get isPercent() { return this.discountType === 'Percent'; }
    get isAmount() { return this.discountType === 'Amount'; }
    get isProductScopeProductFamily() { return this.productScopeType === 'Product Family'; }
    get isProductScopeSpecificProducts() { return this.productScopeType === 'Specific Products'; }

    get discountTypeOptions() { return DISCOUNT_TYPE_OPTIONS; }
    get currencyOptions() { return (this.availableCurrencies || []).map((c) => ({ label: c, value: c })); }
    get memberTypeOptions() { return this._memberTypeOptions; }
    get regionOptions() { return this._regionOptions; }
    get productScopeTypeOptions() { return this._productScopeTypeOptions; }
    get combinationGroupOptions() { return this._combinationGroupOptions; }
    get productFamilyOptions() { return PRODUCT_FAMILY_VALUES; }

    get hasCodeConflicts() { return this.codeConflicts && this.codeConflicts.length > 0; }
    get codeConflictsLabel() { return this.codeConflicts ? this.codeConflicts.join(', ') : ''; }

    get recordCount() {
        if (this.isPercent) return (this.selectedPercentCurrencies || []).length;
        if (this.isAmount) return (this.amounts || []).length;
        return 0;
    }

    get recordPreview() {
        if (this.isPercent) {
            return (this.selectedPercentCurrencies || []).map((c) => ({
                label: `${this.code} — ${c} — ${this.percentValue}% off`
            }));
        }
        if (this.isAmount) {
            return (this.amounts || []).map((a) => ({
                label: `${this.code} — ${a.currencyIsoCode} — ${a.amount} off`
            }));
        }
        return [];
    }

    get totalLimitDisplay() { return this.totalLimit == null ? 'Unlimited' : String(this.totalLimit); }
    get perMemberLimitDisplay() { return this.perMemberLimit == null ? 'Unlimited' : String(this.perMemberLimit); }
    get memberTypeDisplay() { return (this.memberTypeScope || []).length ? this.memberTypeScope.join(', ') : 'All'; }
    get regionDisplay() { return (this.regionScope || []).length ? this.regionScope.join(', ') : 'All'; }
    get productScopeDisplay() {
        if (this.productScopeType === 'All Items') return 'All Items';
        if (this.productScopeType === 'Product Family') return `Product Family: ${this.specificProducts || '(none)'}`;
        return `Specific: ${this.specificProducts || '(none)'}`;
    }
    get accountDisplay() { return this.accountId ? this.accountId : 'Any'; }
    get combinableDisplay() { return this.combinable ? `Yes (group: ${this.combinationGroup})` : 'No'; }
    get approvalDisplay() { return this.approvalRequired ? 'Yes' : 'No'; }

    handleCodeChange(e) {
        const upper = (e.target.value || '').toUpperCase();
        this.code = upper;
        this.codeConflicts = null;
        if (upper && upper.length >= 2) {
            checkCodeUniqueness({ code: upper })
                .then((r) => { this.codeConflicts = r && r.length ? r : null; })
                .catch(() => { this.codeConflicts = null; });
        }
    }
    handleDisplayNameChange(e) { this.displayName = e.target.value; }
    handleTermsChange(e) { this.terms = e.target.value; }
    handleDiscountTypeChange(e) { this.discountType = e.detail.value; }
    handlePercentValueChange(e) {
        const v = e.target.value;
        this.percentValue = v === '' || v == null ? null : parseFloat(v);
    }
    handlePercentCurrenciesChange(e) { this.selectedPercentCurrencies = e.detail.value; }
    handleAmountsChange(e) { this.amounts = e.detail.amounts; }
    handleStartChange(e) { this.effectiveStart = e.target.value; }
    handleEndChange(e) { this.effectiveEnd = e.target.value; }
    handleTotalLimitChange(e) {
        const v = e.target.value;
        this.totalLimit = v === '' || v == null ? null : parseInt(v, 10);
    }
    handlePerMemberLimitChange(e) {
        const v = e.target.value;
        this.perMemberLimit = v === '' || v == null ? null : parseInt(v, 10);
    }
    handleMemberTypeScopeChange(e) { this.memberTypeScope = e.detail.value; }
    handleRegionScopeChange(e) { this.regionScope = e.detail.value; }
    handleProductScopeTypeChange(e) {
        this.productScopeType = e.detail.value;
        if (this.productScopeType === 'All Items') this.specificProducts = '';
    }
    handleProductFamilyChange(e) { this.specificProducts = e.detail.value; }
    handleSpecificProductsChange(e) { this.specificProducts = e.detail.csv; }
    handleAccountChange(e) { this.accountId = e.detail.recordId || null; }
    handleCombinableChange(e) {
        this.combinable = e.target.checked;
        if (!this.combinable) this.combinationGroup = '';
    }
    handleCombinationGroupChange(e) { this.combinationGroup = e.detail.value; }
    handleApprovalRequiredChange(e) { this.approvalRequired = e.target.checked; }

    handleNext() {
        const error = this.validateStep();
        if (error) {
            this.errorMessage = error;
            return;
        }
        this.errorMessage = '';
        if (this.currentStep < TOTAL_STEPS) this.currentStep += 1;
    }

    handleBack() {
        this.errorMessage = '';
        if (this.currentStep > 1) this.currentStep -= 1;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
        this.dispatchEvent(new CustomEvent('close'));
    }

    handleSubmit() {
        const error = this.validateAllSteps();
        if (error) {
            this.errorMessage = error;
            return;
        }
        this.isSubmitting = true;
        this.errorMessage = '';
        const input = this.buildInput();
        createBulk({ input })
            .then((r) => {
                if (r && r.success) {
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Promo Code Created',
                        message: `Created ${r.createdRecordIds.length} record(s) in Draft.`,
                        variant: 'success'
                    }));
                    if (r.createdRecordIds && r.createdRecordIds.length === 1) {
                        this[NavigationMixin.Navigate]({
                            type: 'standard__recordPage',
                            attributes: {
                                recordId: r.createdRecordIds[0],
                                objectApiName: 'Promo_Code__c',
                                actionName: 'view'
                            }
                        });
                    }
                    this.dispatchEvent(new CloseActionScreenEvent());
                    this.dispatchEvent(new CustomEvent('close'));
                } else {
                    this.errorMessage = (r && r.errorMessage) || 'Save failed.';
                }
            })
            .catch((err) => {
                this.errorMessage = (err && err.body && err.body.message) || (err && err.message) || 'Save failed.';
            })
            .finally(() => {
                this.isSubmitting = false;
            });
    }

    validateStep() {
        switch (this.currentStep) {
            case 1:
                if (!this.code || !this.code.trim()) return 'Code is required.';
                if (!/^[A-Z0-9]+$/.test(this.code)) return 'Code must be uppercase alphanumeric only.';
                if (!this.displayName || !this.displayName.trim()) return 'Display Name is required.';
                return null;
            case 2:
                if (!this.discountType) return 'Select a Discount Type.';
                return null;
            case 3:
                if (this.isPercent) {
                    if (this.percentValue == null || this.percentValue <= 0 || this.percentValue > 100) {
                        return 'Percent must be greater than 0 and at most 100.';
                    }
                    if (!this.selectedPercentCurrencies || this.selectedPercentCurrencies.length === 0) {
                        return 'Select at least one currency.';
                    }
                } else if (this.isAmount) {
                    if (!this.amounts || this.amounts.length === 0) {
                        return 'Add at least one currency-amount row.';
                    }
                    if (this.amounts.some((a) => !a.currencyIsoCode || !(a.amount > 0))) {
                        return 'Every row needs a currency and an amount greater than 0.';
                    }
                }
                return null;
            case 4:
                if (!this.effectiveStart) return 'Effective Start is required.';
                if (!this.effectiveEnd) return 'Effective End is required.';
                if (new Date(this.effectiveEnd) <= new Date(this.effectiveStart)) {
                    return 'Effective End must be after Effective Start.';
                }
                return null;
            case 6:
                if (this.productScopeType === 'Product Family' && !this.specificProducts) {
                    return 'Pick a Product Family (Membership / Chapter / Section).';
                }
                if (this.productScopeType === 'Specific Products' && !this.specificProducts) {
                    return 'Pick at least one specific product.';
                }
                return null;
            case 7:
                if (this.combinable && !this.combinationGroup) {
                    return 'Combination Group is required when Combinable is true.';
                }
                return null;
            default:
                return null;
        }
    }

    validateAllSteps() {
        const original = this.currentStep;
        for (let s = 1; s <= TOTAL_STEPS; s += 1) {
            this.currentStep = s;
            const e = this.validateStep();
            if (e) {
                return `Step ${s} (${STEP_TITLES[s]}): ${e}`;
            }
        }
        this.currentStep = original;
        return null;
    }

    buildInput() {
        return {
            code: this.code.trim(),
            displayName: this.displayName,
            terms: this.terms,
            discountType: this.discountType,
            percentValue: this.isPercent ? this.percentValue : null,
            percentCurrencies: this.isPercent ? this.selectedPercentCurrencies : null,
            amounts: this.isAmount ? this.amounts : null,
            effectiveStart: this.effectiveStart || null,
            effectiveEnd: this.effectiveEnd || null,
            totalLimit: this.totalLimit,
            perMemberLimit: this.perMemberLimit,
            memberTypeScope: this.memberTypeScope,
            regionScope: this.regionScope,
            productScopeType: this.productScopeType,
            specificProducts: this.specificProducts,
            accountId: this.accountId,
            combinable: this.combinable,
            combinationGroup: this.combinationGroup,
            approvalRequired: this.approvalRequired
        };
    }
}
