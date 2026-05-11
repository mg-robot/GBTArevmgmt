import { LightningElement, api } from 'lwc';
import searchProducts from '@salesforce/apex/PromoCodeService.searchProducts';

import LBL_SearchLabel from '@salesforce/label/c.PromoCodeWizard_PP_Search_Label';
import LBL_SearchPlaceholder from '@salesforce/label/c.PromoCodeWizard_PP_SearchPlaceholder';
import LBL_Searching from '@salesforce/label/c.PromoCodeWizard_PP_Searching';
import LBL_SelectedTemplate from '@salesforce/label/c.PromoCodeWizard_PP_SelectedTemplate';

/**
 * Multi-select picker for the Specific Products promo scope.
 *
 * Storage contract: persists a CSV of Product2.ProductCode values via the `change` event's
 * `detail.csv`. This aligns with PromoCodeAllocationEngine, which matches eligible OrderItems
 * by Product2.ProductCode (case-insensitive, trim) under
 * Product_Scope_Type__c = 'Specific Products'.
 *
 * Display:
 *   - Search results render as "Product Code — Product Name" so staff can disambiguate while
 *     selecting.
 *   - Pills show "Product Code — Product Name" when added via search; pills loaded from
 *     `initialCsv` (edit flow) show just the code, since we don't round-trip names for
 *     pre-existing codes in v1.
 *
 * Pre-existing data with Product Names (from before the apply-flow contract switched to
 * ProductCode) will not match cart lines at apply time — staff must re-pick those products via
 * the wizard to convert them to codes.
 */
export default class PromoSpecificProductPicker extends LightningElement {
    @api initialCsv = '';

    searchTerm = '';
    results = [];
    selected = [];
    loading = false;

    label = {
        searchLabel: LBL_SearchLabel,
        searchPlaceholder: LBL_SearchPlaceholder,
        searching: LBL_Searching
    };

    connectedCallback() {
        if (this.initialCsv) {
            const codes = this.initialCsv
                .split(',')
                .map((s) => s.trim())
                .filter(Boolean);
            this.selected = codes.map((code) => ({ code, label: code }));
        }
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get hasSelected() {
        return this.selected.length > 0;
    }

    get selectedHeader() {
        return LBL_SelectedTemplate.replace('{0}', this.selected.length);
    }

    handleSearch(e) {
        this.searchTerm = e.target.value || '';
        if (this.searchTerm.length < 2) {
            this.results = [];
            return;
        }
        this.loading = true;
        searchProducts({ searchTerm: this.searchTerm })
            .then((r) => {
                const taken = new Set(this.selected.map((s) => s.code));
                this.results = (r || []).filter((p) => p.productCode && !taken.has(p.productCode));
            })
            .catch(() => {
                this.results = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    addProduct(e) {
        const code = e.currentTarget.dataset.code;
        const name = e.currentTarget.dataset.name;
        if (!code) return;
        if (!this.selected.some((s) => s.code === code)) {
            const label = name ? `${code} — ${name}` : code;
            this.selected = [...this.selected, { code, label }];
            this.fireChange();
        }
        this.results = this.results.filter((r) => r.productCode !== code);
    }

    removeProduct(e) {
        const code = e.target.name;
        this.selected = this.selected.filter((s) => s.code !== code);
        this.fireChange();
    }

    fireChange() {
        const csv = this.selected.map((s) => s.code).join(',');
        this.dispatchEvent(
            new CustomEvent('change', { detail: { csv, count: this.selected.length } })
        );
    }
}
