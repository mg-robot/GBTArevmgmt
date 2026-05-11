import LightningModal from 'lightning/modal';
import createBulk from '@salesforce/apex/PromoCodeService.createBulk';
import getActiveCurrencies from '@salesforce/apex/PromoCodeService.getActiveCurrencies';

import LBL_ModalTitle from '@salesforce/label/c.PromoCodeWizard_Modal_Title';
import LBL_BtnCancel from '@salesforce/label/c.PromoCodeWizard_Btn_Cancel';
import LBL_BtnBack from '@salesforce/label/c.PromoCodeWizard_Btn_Back';
import LBL_BtnNext from '@salesforce/label/c.PromoCodeWizard_Btn_Next';
import LBL_BtnSaveAsDraft from '@salesforce/label/c.PromoCodeWizard_Btn_SaveAsDraft';
import LBL_BtnActivateNow from '@salesforce/label/c.PromoCodeWizard_Btn_ActivateNow';
import LBL_Saving from '@salesforce/label/c.PromoCodeWizard_Saving';
import LBL_CancelConfirm from '@salesforce/label/c.PromoCodeWizard_CancelConfirm';
import LBL_SaveFailed from '@salesforce/label/c.PromoCodeWizard_SaveFailed';
import LBL_StepDefinition from '@salesforce/label/c.PromoCodeWizard_Step_Definition';
import LBL_StepScopeEligibility from '@salesforce/label/c.PromoCodeWizard_Step_ScopeEligibility';
import LBL_StepLimitsBehavior from '@salesforce/label/c.PromoCodeWizard_Step_LimitsBehavior';
import LBL_StepReviewActivate from '@salesforce/label/c.PromoCodeWizard_Step_ReviewActivate';

/**
 * Promo Code creation wizard modal. Opened via PromoCodeWizard.open() from a launcher.
 * 4 steps: Definition / Scope & Eligibility / Limits & Behavior / Review & Activate.
 * On Step 4, staff choose Save as Draft (Status=Draft) or Activate Now (Status=Active).
 * Apex creates N records (one per currency) in a single transaction.
 *
 * All user-facing text is sourced from Custom Labels for translation via Translation Workbench.
 */
export default class PromoCodeWizard extends LightningModal {
    currentStep = 1;
    isSubmitting = false;
    errorMessage = '';
    availableCurrencies = [];

    label = {
        modalTitle: LBL_ModalTitle,
        btnCancel: LBL_BtnCancel,
        btnBack: LBL_BtnBack,
        btnNext: LBL_BtnNext,
        btnSaveAsDraft: LBL_BtnSaveAsDraft,
        btnActivateNow: LBL_BtnActivateNow,
        saving: LBL_Saving,
        stepDefinition: LBL_StepDefinition,
        stepScopeEligibility: LBL_StepScopeEligibility,
        stepLimitsBehavior: LBL_StepLimitsBehavior,
        stepReviewActivate: LBL_StepReviewActivate
    };

    wizardData = {
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
        combinable: false,
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
            if (!window.confirm(LBL_CancelConfirm)) {
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
        const w = this.wizardData || {};
        const isPercent = w.discountType === 'Percent';
        const isAmount = w.discountType === 'Amount';
        const input = {
            code: w.code,
            displayName: w.displayName,
            terms: w.terms,
            discountType: w.discountType,
            percentValue: isPercent ? w.percentValue : null,
            percentCurrencies: isPercent ? w.percentCurrencies : null,
            amounts: isAmount ? w.amounts : null,
            effectiveStart: w.effectiveStart || null,
            effectiveEnd: w.effectiveEnd || null,
            totalLimit: w.totalLimit === '' || w.totalLimit == null ? null : w.totalLimit,
            perMemberLimit: w.perMemberLimit === '' || w.perMemberLimit == null ? null : w.perMemberLimit,
            memberTypeScope: w.memberTypeScope,
            regionScope: w.regionScope,
            productScopeType: w.productScopeType,
            specificProducts: w.specificProducts,
            accountId: w.accountId,
            combinable: w.combinable,
            combinationGroup: w.combinationGroup,
            approvalRequired: w.approvalRequired,
            activateImmediately: activate
        };

        const cleanInput = JSON.parse(JSON.stringify(input));
        createBulk({ input: cleanInput })
            .then((r) => {
                if (r && r.success) {
                    try {
                        this.close('created');
                    } catch (closeErr) {
                        try { this.close(); } catch (e2) { /* swallow */ }
                    }
                } else {
                    this.errorMessage = (r && r.errorMessage) || LBL_SaveFailed;
                    if (r && r.conflictCurrencies && r.conflictCurrencies.length) {
                        this.currentStep = 1;
                    }
                }
            })
            .catch((err) => {
                this.errorMessage = (err && err.body && err.body.message) || (err && err.message) || LBL_SaveFailed;
            })
            .finally(() => {
                this.isSubmitting = false;
            });
    }
}
