import { track } from 'lwc';
import LightningModal from 'lightning/modal';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import createBulk from '@salesforce/apex/PromoCodeService.createBulk';
import getActiveCurrencies from '@salesforce/apex/PromoCodeService.getActiveCurrencies';

/**
 * Promo Code creation wizard modal. Opened via PromoCodeWizard.open() from a launcher.
 * 4 steps: Definition / Scope & Eligibility / Limits & Behavior / Review & Activate.
 * On Step 4, staff choose Save as Draft (Status=Draft) or Activate Now (Status=Active).
 * Apex creates N records (one per currency) in a single transaction.
 */
export default class PromoCodeWizard extends LightningModal {
    currentStep = 1;
    isSubmitting = false;
    errorMessage = '';
    availableCurrencies = [];

    @track wizardData = {
        code: '',
        displayName: '',
        terms: '',
        discountType: '',
        percentValue: null,
        percentCurrencies: [],
        amounts: [],
        effectiveStart: '',
        effectiveEnd: '',
        memberTypeScope: [],
        regionScope: [],
        productScopeType: 'All Items',
        specificProducts: '',
        accountId: null,
        totalLimit: null,
        perMemberLimit: null,
        combinable: true,
        combinationGroup: '',
        approvalRequired: false
    };

    stepValidationStatus = { 1: false, 2: false, 3: false, 4: true };

    connectedCallback() {
        getActiveCurrencies()
            .then((r) => {
                this.availableCurrencies = r || [];
                if (this.wizardData.percentCurrencies.length === 0 && this.availableCurrencies.length) {
                    this.wizardData = { ...this.wizardData, percentCurrencies: [...this.availableCurrencies] };
                }
            })
            .catch(() => {});
    }

    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }
    get isStep3() { return this.currentStep === 3; }
    get isStep4() { return this.currentStep === 4; }
    get isFirstStep() { return this.currentStep === 1; }
    get isReviewStep() { return this.currentStep === 4; }
    get progressValue() { return `step${this.currentStep}`; }
    get nextDisabled() { return !this.stepValidationStatus[this.currentStep]; }

    handleFieldChange(event) {
        const { field, value } = event.detail;
        this.wizardData = { ...this.wizardData, [field]: value };
    }

    handleStepValidate(event) {
        this.stepValidationStatus = { ...this.stepValidationStatus, [this.currentStep]: !!event.detail.valid };
    }

    handleNext() {
        if (!this.stepValidationStatus[this.currentStep]) return;
        if (this.currentStep < 4) {
            this.currentStep += 1;
            this.errorMessage = '';
        }
    }

    handleBack() {
        if (this.currentStep > 1) {
            this.currentStep -= 1;
            this.errorMessage = '';
        }
    }

    handleProgressClick(event) {
        const value = event && event.detail && event.detail.value;
        if (!value) return;
        const targetStep = parseInt(String(value).replace('step', ''), 10);
        if (!isNaN(targetStep) && targetStep < this.currentStep) {
            this.currentStep = targetStep;
            this.errorMessage = '';
        }
    }

    handleJumpTo(event) {
        const targetStep = parseInt(event.detail.step, 10);
        if (!isNaN(targetStep) && targetStep >= 1 && targetStep <= 4) {
            this.currentStep = targetStep;
        }
    }

    handleCancel() {
        const hasData = this.wizardData.code || this.wizardData.displayName || this.wizardData.discountType;
        if (hasData) {
            // eslint-disable-next-line no-alert
            if (!window.confirm('Discard your in-progress promo code? All entered data will be lost.')) {
                return;
            }
        }
        this.close({ result: 'cancelled' });
    }

    handleSaveDraft() { this.submit(false); }
    handleActivateNow() { this.submit(true); }

    submit(activate) {
        this.isSubmitting = true;
        this.errorMessage = '';
        const input = { ...this.wizardData, activateImmediately: activate };
        if (input.discountType === 'Percent') {
            input.amounts = null;
        } else if (input.discountType === 'Amount') {
            input.percentValue = null;
            input.percentCurrencies = null;
        }
        input.effectiveStart = input.effectiveStart || null;
        input.effectiveEnd = input.effectiveEnd || null;
        input.totalLimit = input.totalLimit === '' ? null : input.totalLimit;
        input.perMemberLimit = input.perMemberLimit === '' ? null : input.perMemberLimit;

        createBulk({ input })
            .then((r) => {
                if (r && r.success) {
                    const action = activate ? 'created and activated' : 'saved as draft';
                    const count = r.createdRecordIds ? r.createdRecordIds.length : 0;
                    this.dispatchEvent(new ShowToastEvent({
                        title: 'Promo Code',
                        message: `${count} promo code${count === 1 ? '' : 's'} ${action}.`,
                        variant: 'success'
                    }));
                    this.close({
                        result: 'created',
                        recordIds: r.createdRecordIds,
                        status: r.status
                    });
                } else {
                    this.errorMessage = (r && r.errorMessage) || 'Save failed.';
                    if (r && r.conflictCurrencies && r.conflictCurrencies.length) {
                        this.currentStep = 1;
                    }
                }
            })
            .catch((err) => {
                this.errorMessage = (err && err.body && err.body.message) || (err && err.message) || 'Save failed.';
            })
            .finally(() => {
                this.isSubmitting = false;
            });
    }
}
