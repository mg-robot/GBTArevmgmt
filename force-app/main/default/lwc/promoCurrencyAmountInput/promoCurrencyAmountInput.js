import { LightningElement, api } from 'lwc';

import LBL_Heading from '@salesforce/label/c.PromoCodeWizard_Amt_Heading';
import LBL_AddRow from '@salesforce/label/c.PromoCodeWizard_Amt_AddRow';
import LBL_SelectCurrency from '@salesforce/label/c.PromoCodeWizard_Amt_SelectCurrency';
import LBL_AmountPlaceholder from '@salesforce/label/c.PromoCodeWizard_Amt_AmountPlaceholder';
import LBL_Remove from '@salesforce/label/c.PromoCodeWizard_Amt_Remove';
import LBL_NoRows from '@salesforce/label/c.PromoCodeWizard_Amt_NoRows';

export default class PromoCurrencyAmountInput extends LightningElement {
    @api availableCurrencies = [];
    @api initialAmounts = [];

    rows = [];
    nextKey = 1;

    label = {
        heading: LBL_Heading,
        addRow: LBL_AddRow,
        selectCurrency: LBL_SelectCurrency,
        amountPlaceholder: LBL_AmountPlaceholder,
        remove: LBL_Remove,
        noRows: LBL_NoRows
    };

    connectedCallback() {
        if (this.initialAmounts && this.initialAmounts.length) {
            this.rows = this.initialAmounts.map((a) => ({
                key: this.nextKey++,
                currencyIsoCode: a.currencyIsoCode,
                amount: a.amount,
                options: []
            }));
            this.recalcOptions();
        } else {
            this.addRow();
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
        this.rows = this.rows.map((r, i) => (i === idx ? { ...r, currencyIsoCode: newIso } : r));
        this.recalcOptions();
        this.fireChange();
    }

    handleAmountChange(e) {
        const idx = parseInt(e.currentTarget.dataset.idx, 10);
        if (isNaN(idx) || !this.rows[idx]) return;
        const v = e.target.value;
        const newAmount = v === '' || v == null || isNaN(parseFloat(v)) ? null : parseFloat(v);
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
