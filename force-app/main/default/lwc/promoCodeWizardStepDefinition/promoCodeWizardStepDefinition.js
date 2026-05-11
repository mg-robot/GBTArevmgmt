import { LightningElement, api } from 'lwc';
import checkCodeUniqueness from '@salesforce/apex/PromoCodeService.checkCodeUniqueness';

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' }
];

/**
 * Step 1 of the wizard. Captures Code, Display Name, Terms, Discount Type, and Discount Value.
 * Dispatches `fieldchange` per change and `stepvalidate` whenever validity changes.
 */
export default class PromoCodeWizardStepDefinition extends LightningElement {
    @api wizardData;
    @api availableCurrencies;

    codeConflicts = null;
    _debounceTimer;

    get discountTypeOptions() { return DISCOUNT_TYPE_OPTIONS; }
    get hasType() { return !!this.wizardData?.discountType; }
    get isPercent() { return this.wizardData?.discountType === 'Percent'; }
    get isAmount() { return this.wizardData?.discountType === 'Amount'; }
    get currencyOptions() {
        return (this.availableCurrencies || []).map((c) => ({ label: c, value: c }));
    }
    get hasCodeConflicts() { return this.codeConflicts && this.codeConflicts.length > 0; }
    get codeConflictsLabel() { return this.codeConflicts ? this.codeConflicts.join(', ') : ''; }

    connectedCallback() {
        Promise.resolve().then(() => this.fireValidate());
    }

    renderedCallback() {
        Promise.resolve().then(() => this.fireValidate());
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
    handleAmountsChange(e) { this.dispatch('amounts', e.detail.amounts); }

    dispatch(field, value) {
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
    }

    fireValidate() {
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid: this.computeValid() } }));
    }

    computeValid() {
        const d = this.wizardData;
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
        }
        return true;
    }
}
