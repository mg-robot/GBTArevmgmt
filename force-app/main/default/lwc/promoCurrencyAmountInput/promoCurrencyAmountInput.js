import { LightningElement, api } from 'lwc';

export default class PromoCurrencyAmountInput extends LightningElement {
    @api availableCurrencies = [];
    @api initialAmounts = [];

    rows = [];
    nextKey = 1;

    connectedCallback() {
        if (this.initialAmounts && this.initialAmounts.length) {
            this.rows = this.initialAmounts.map((a) => ({
                key: this.nextKey++,
                currencyIsoCode: a.currencyIsoCode,
                amount: a.amount,
                options: []
            }));
            this.recalcOptions();
        }
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    optionsExcluding(allowedIso) {
        const taken = new Set(this.rows.map((r) => r.currencyIsoCode).filter(Boolean));
        if (allowedIso) taken.delete(allowedIso);
        return (this.availableCurrencies || [])
            .filter((c) => !taken.has(c))
            .map((c) => ({ label: c, value: c }));
    }

    recalcOptions() {
        this.rows = this.rows.map((r) => ({
            ...r,
            options: this.optionsExcluding(r.currencyIsoCode)
        }));
    }

    addRow() {
        this.rows = [
            ...this.rows,
            { key: this.nextKey++, currencyIsoCode: '', amount: null, options: [] }
        ];
        this.recalcOptions();
        this.fireChange();
    }

    removeRow(e) {
        const idx = parseInt(e.currentTarget.dataset.idx, 10);
        this.rows = this.rows.filter((_, i) => i !== idx);
        this.recalcOptions();
        this.fireChange();
    }

    handleCurrencyChange(e) {
        const idx = parseInt(e.currentTarget.dataset.idx, 10);
        const newIso = e.detail.value;
        // Use map (not in-place mutation) so the reactivity tracker definitely sees the change.
        this.rows = this.rows.map((r, i) => (i === idx ? { ...r, currencyIsoCode: newIso } : r));
        this.recalcOptions();
        this.fireChange();
    }

    handleAmountChange(e) {
        const idx = parseInt(e.currentTarget.dataset.idx, 10);
        if (isNaN(idx) || !this.rows[idx]) return;
        const v = e.target.value;
        const newAmount = v === '' || v == null || isNaN(parseFloat(v)) ? null : parseFloat(v);
        // Idempotent — same handler is wired to onchange, oninput, AND onblur so we don't
        // miss a value commit. Skip work if the value hasn't actually changed.
        if (this.rows[idx].amount === newAmount) return;
        this.rows = this.rows.map((r, i) => (i === idx ? { ...r, amount: newAmount } : r));
        this.fireChange();
    }

    fireChange() {
        const amounts = this.rows
            .filter((r) => r.currencyIsoCode && r.amount > 0)
            .map((r) => ({ currencyIsoCode: r.currencyIsoCode, amount: r.amount }));
        const valid = this.rows.length > 0 && amounts.length === this.rows.length;
        this.dispatchEvent(new CustomEvent('change', { detail: { amounts, valid } }));
    }
}
