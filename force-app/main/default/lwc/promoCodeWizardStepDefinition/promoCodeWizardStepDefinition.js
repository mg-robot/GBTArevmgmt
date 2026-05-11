import { LightningElement, api } from 'lwc';
import checkCodeUniqueness from '@salesforce/apex/PromoCodeService.checkCodeUniqueness';

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' }
];

/**
 * Step 1 of the wizard. Captures Code, Display Name, Terms, Discount Type, and Discount Value.
 * Dispatches `fieldchange` per change and `stepvalidate` synchronously against the predicted
 * next wizard state — this avoids the lag where validation would otherwise wait for the parent
 * to commit + re-render before re-validating.
 */
export default class PromoCodeWizardStepDefinition extends LightningElement {
    @api wizardData;
    @api availableCurrencies;

    codeConflicts = null;
    _debounceTimer;
    // Tracks whether the embedded promoCurrencyAmountInput has any incomplete rows.
    // The child filters those out of its `amounts` payload, so the parent step needs the
    // raw validity flag to detect "user added an empty row" and disable Next.
    _amountsRowsComplete = true;

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
        this.fireValidate(this.wizardData);
    }

    renderedCallback() {
        this.fireValidate(this.wizardData);
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
        // Child fires both the filtered amounts payload AND its own validity flag.
        // We need the flag because the filtered payload alone can't distinguish
        // "1 valid row" from "1 valid row + 1 empty row" — both look like length-1 amounts.
        this._amountsRowsComplete = !!e.detail.valid;
        this.dispatch('amounts', e.detail.amounts);
    }

    dispatch(field, value) {
        this.dispatchEvent(new CustomEvent('fieldchange', { detail: { field, value } }));
        // Validate against the PREDICTED next state instead of waiting for the parent
        // to commit + re-render. Otherwise the user can click Next before the validity
        // check has caught up.
        const predicted = { ...(this.wizardData || {}), [field]: value };
        this.fireValidate(predicted);
    }

    fireValidate(data) {
        this.dispatchEvent(new CustomEvent('stepvalidate', { detail: { valid: this.computeValid(data) } }));
    }

    computeValid(data) {
        const d = data || this.wizardData;
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
