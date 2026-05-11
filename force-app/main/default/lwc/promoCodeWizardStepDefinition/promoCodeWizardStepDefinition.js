import { LightningElement, api } from 'lwc';
import checkCodeUniqueness from '@salesforce/apex/PromoCodeService.checkCodeUniqueness';

import LBL_IdentityHeading from '@salesforce/label/c.PromoCodeWizard_S1_Identity_Heading';
import LBL_IdentityHelper from '@salesforce/label/c.PromoCodeWizard_S1_Identity_Helper';
import LBL_CodeLabel from '@salesforce/label/c.PromoCodeWizard_S1_Code_Label';
import LBL_CodePatternError from '@salesforce/label/c.PromoCodeWizard_S1_Code_PatternError';
import LBL_CodeConflictPrefix from '@salesforce/label/c.PromoCodeWizard_S1_Code_ConflictPrefix';
import LBL_CodeConflictSuffix from '@salesforce/label/c.PromoCodeWizard_S1_Code_ConflictSuffix';
import LBL_DisplayName from '@salesforce/label/c.PromoCodeWizard_S1_DisplayName_Label';
import LBL_Terms from '@salesforce/label/c.PromoCodeWizard_S1_Terms_Label';
import LBL_TermsHelper from '@salesforce/label/c.PromoCodeWizard_S1_Terms_Helper';
import LBL_DiscDetailsHeading from '@salesforce/label/c.PromoCodeWizard_S1_DiscDetails_Heading';
import LBL_DiscTypeLabel from '@salesforce/label/c.PromoCodeWizard_S1_DiscType_Label';
import LBL_DiscTypePercent from '@salesforce/label/c.PromoCodeWizard_S1_DiscType_Percent';
import LBL_DiscTypeAmount from '@salesforce/label/c.PromoCodeWizard_S1_DiscType_Amount';
import LBL_DiscValueHeading from '@salesforce/label/c.PromoCodeWizard_S1_DiscValue_Heading';
import LBL_DiscValuePercentHelper from '@salesforce/label/c.PromoCodeWizard_S1_DiscValue_PercentHelper';
import LBL_DiscValueAmountHelper from '@salesforce/label/c.PromoCodeWizard_S1_DiscValue_AmountHelper';
import LBL_PercentOff from '@salesforce/label/c.PromoCodeWizard_S1_PercentOff_Label';
import LBL_Currencies from '@salesforce/label/c.PromoCodeWizard_S1_Currencies_Label';

/**
 * Step 1 of the wizard. Captures Code, Display Name, Terms, Discount Type, and Discount Value.
 * Maintains a local snapshot updated synchronously on every change so validation is always
 * current regardless of when the @api wizardData binding refreshes.
 * All user-facing text is sourced from Custom Labels.
 */
export default class PromoCodeWizardStepDefinition extends LightningElement {
    @api wizardData;
    @api availableCurrencies;

    _localData = {};
    _initialized = false;
    codeConflicts = null;
    _debounceTimer;
    _amountsRowsComplete = true;

    label = {
        identityHeading: LBL_IdentityHeading,
        identityHelper: LBL_IdentityHelper,
        codeLabel: LBL_CodeLabel,
        codePatternError: LBL_CodePatternError,
        codeConflictPrefix: LBL_CodeConflictPrefix,
        codeConflictSuffix: LBL_CodeConflictSuffix,
        displayName: LBL_DisplayName,
        terms: LBL_Terms,
        termsHelper: LBL_TermsHelper,
        discDetailsHeading: LBL_DiscDetailsHeading,
        discTypeLabel: LBL_DiscTypeLabel,
        discValueHeading: LBL_DiscValueHeading,
        discValuePercentHelper: LBL_DiscValuePercentHelper,
        discValueAmountHelper: LBL_DiscValueAmountHelper,
        percentOff: LBL_PercentOff,
        currencies: LBL_Currencies
    };

    discountTypeOptions = [
        { label: LBL_DiscTypePercent, value: 'Percent' },
        { label: LBL_DiscTypeAmount, value: 'Amount' }
    ];

    get hasType() { return !!this._localData.discountType; }
    get isPercent() { return this._localData.discountType === 'Percent'; }
    get isAmount() { return this._localData.discountType === 'Amount'; }
    get currencyOptions() {
        return (this.availableCurrencies || []).map((c) => ({ label: c, value: c }));
    }
    get hasCodeConflicts() { return this.codeConflicts && this.codeConflicts.length > 0; }
    get codeConflictsLabel() { return this.codeConflicts ? this.codeConflicts.join(', ') : ''; }
    get d() { return this._localData; }

    connectedCallback() {
        this._localData = { ...(this.wizardData || {}) };
        this._initialized = true;
        this.fireValidate();
    }

    renderedCallback() {
        if (this._initialized && this.wizardData) {
            let resynced = false;
            for (const k of Object.keys(this.wizardData)) {
                if (this._localData[k] === undefined && this.wizardData[k] !== undefined) {
                    this._localData = { ...this._localData, [k]: this.wizardData[k] };
                    resynced = true;
                }
            }
            if (resynced) this.fireValidate();
        }
    }

    handleCodeChange(e) {
        const upper = (e.target.value || '').toUpperCase();
        this.dispatch('code', upper);
        this.codeConflicts = null;
        clearTimeout(this._debounceTimer);
        if (upper.length >= 2) {
            this._debounceTimer = setTimeout(() => {
                checkCodeUniqueness({ code: upper })
                    .then((r) => { this.codeConflicts = r && r.length ? r : null; })
                    .catch(() => { this.codeConflicts = null; });
            }, 400);
        }
    }
    handleDisplayNameChange(e) { this.dispatch('displayName', e.target.value); }
    handleTermsChange(e) { this.dispatch('terms', e.target.value); }
    handleDiscountTypeChange(e) { this.dispatch('discountType', e.detail.value); }
    handlePercentValueChange(e) {
        const v = e.target.value;
        this.dispatch('percentValue', v === '' || v == null ? null : parseFloat(v));
    }
    handlePercentCurrenciesChange(e) { this.dispatch('percentCurrencies', e.detail.value); }

    handleAmountsChange(e) {
        this._amountsRowsComplete = !!e.detail.valid;
        this.dispatch('amounts', e.detail.amounts);
    }

    dispatch(field, value) {
        this._localData = { ...this._localData, [field]: value };
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
        this.fireValidate();
    }

    fireValidate() {
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid: this.computeValid() } }));
    }

    computeValid() {
        const d = this._localData;
        if (!d) return false;
        if (!d.code || !/^[A-Z0-9]+$/.test(d.code)) return false;
        if (!d.displayName || !d.displayName.trim()) return false;
        if (!d.discountType) return false;
        if (d.discountType === 'Percent') {
            if (d.percentValue == null || d.percentValue <= 0 || d.percentValue > 100) return false;
            if (!d.percentCurrencies || d.percentCurrencies.length === 0) return false;
        } else if (d.discountType === 'Amount') {
            if (!d.amounts || d.amounts.length === 0) return false;
            if (d.amounts.some((a) => !a.currencyIsoCode || !(a.amount > 0))) return false;
            if (!this._amountsRowsComplete) return false;
        }
        return true;
    }
}
