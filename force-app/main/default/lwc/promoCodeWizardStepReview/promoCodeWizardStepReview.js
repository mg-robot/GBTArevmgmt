import { LightningElement, api } from 'lwc';

/**
 * Step 4 of the wizard. Renders a read-only summary of every input from Steps 1-3
 * plus a per-currency preview of records that will be created. Emits `jumpto` when
 * the user clicks an Edit link on a section.
 */
export default class PromoCodeWizardStepReview extends LightningElement {
    @api wizardData;

    get isPercent() { return this.wizardData?.discountType === 'Percent'; }
    get isAmount() { return this.wizardData?.discountType === 'Amount'; }

    get recordCount() {
        if (!this.wizardData) return 0;
        if (this.isPercent) return (this.wizardData.percentCurrencies || []).length;
        if (this.isAmount) return (this.wizardData.amounts || []).length;
        return 0;
    }

    get recordPreview() {
        if (!this.wizardData) return [];
        if (this.isPercent) {
            return (this.wizardData.percentCurrencies || []).map((c) => ({
                label: `${this.wizardData.code} — ${c} — ${this.wizardData.percentValue}% off`
            }));
        }
        if (this.isAmount) {
            return (this.wizardData.amounts || []).map((a) => ({
                label: `${this.wizardData.code} — ${a.currencyIsoCode} — ${a.amount} off`
            }));
        }
        return [];
    }

    get discountValueDisplay() {
        const d = this.wizardData;
        if (!d) return '';
        if (this.isPercent) return `${d.percentValue}% off in ${(d.percentCurrencies || []).join(', ')}`;
        if (this.isAmount) {
            return (d.amounts || [])
                .map((a) => `${a.amount} ${a.currencyIsoCode}`)
                .join(', ');
        }
        return '';
    }

    get effectiveDisplay() {
        const s = this.wizardData?.effectiveStart || '(no start)';
        const e = this.wizardData?.effectiveEnd || '(no end)';
        return `${s} → ${e}`;
    }
    get memberTypeDisplay() {
        const arr = this.wizardData?.memberTypeScope || [];
        return arr.length ? arr.join(', ') : 'All';
    }
    get regionDisplay() {
        const arr = this.wizardData?.regionScope || [];
        return arr.length ? arr.join(', ') : 'All';
    }
    get productScopeDisplay() {
        const t = this.wizardData?.productScopeType;
        const v = this.wizardData?.specificProducts;
        if (t === 'All Items') return 'All Items';
        if (t === 'Product Family') return `Product Family: ${v || '(none)'}`;
        if (t === 'Specific Products') return `Specific: ${v || '(none)'}`;
        return '—';
    }
    get accountDisplay() { return this.wizardData?.accountId || 'Any'; }
    get totalLimitDisplay() {
        return this.wizardData?.totalLimit == null ? 'Unlimited' : String(this.wizardData.totalLimit);
    }
    get perMemberLimitDisplay() {
        return this.wizardData?.perMemberLimit == null ? 'Unlimited' : String(this.wizardData.perMemberLimit);
    }
    get combinableDisplay() {
        if (!this.wizardData?.combinable) return 'No';
        return `Yes (group: ${this.wizardData.combinationGroup || '—'})`;
    }
    get approvalDisplay() { return this.wizardData?.approvalRequired ? 'Yes' : 'No'; }

    handleEditClick(event) {
        event.preventDefault();
        const step = event.currentTarget.dataset.step;
        this.dispatchEvent(new CustomEvent('jumpto', { detail: { step } }));
    }
}
