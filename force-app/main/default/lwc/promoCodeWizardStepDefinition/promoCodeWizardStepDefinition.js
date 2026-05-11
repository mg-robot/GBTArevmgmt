import { LightningElement, api } from 'lwc';
import checkCodeUniqueness from '@salesforce/apex/PromoCodeService.checkCodeUniqueness';

const DISCOUNT_TYPE_OPTIONS = [
    { label: 'Percent', value: 'Percent' },
    { label: 'Amount', value: 'Amount' }
];

/**
 * Step 1 of the wizard. Captures Code, Display Name, Terms, Discount Type, and Discount Value.
 *
 * State strategy: this step maintains a local snapshot (`_localData`) that is updated
 * synchronously on every field change. Validation is computed against `_localData`, not
 * against `@api wizardData` (which is updated by the parent on a microtask after the
 * `fieldchange` event bubbles up — meaning it can be stale for fields touched in earlier
 * dispatches). This guarantees the Next button's enabled state reflects every keystroke
 * the user has committed, no matter how fast they click.
 */
export default class PromoCodeWizardStepDefinition extends LightningElement {
    @api wizardData;
    @api availableCurrencies;

    _localData = {};
    _initialized = false;
    codeConflicts = null;
    _debounceTimer;
    // Tracks whether the embedded promoCurrencyAmountInput has any incomplete rows.
    // The child filters those out of its `amounts` payload, so the step needs the raw
    // validity flag to detect "user added an empty row" and disable Next.
    _amountsRowsComplete = true;

    get discountTypeOptions() { return DISCOUNT_TYPE_OPTIONS; }
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
        // If the wizardData reference changed externally (e.g., wizard reset, navigate
        // away and back), pull in any fields we haven't yet captured locally.
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
        // Child fires both the filtered amounts payload AND its own validity flag.
        // We need the flag because the filtered payload alone can't distinguish
        // "1 valid row" from "1 valid row + 1 empty row" — both look like length-1 amounts.
        this._amountsRowsComplete = !!e.detail.valid;
        this.dispatch('amounts', e.detail.amounts);
    }

    dispatch(field, value) {
        // Update local snapshot synchronously so validation immediately reflects this change
        // alongside every previous change.
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
