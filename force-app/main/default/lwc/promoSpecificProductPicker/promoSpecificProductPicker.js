import { LightningElement, api } from 'lwc';
import searchProducts from '@salesforce/apex/PromoCodeService.searchProducts';

import LBL_SearchLabel from '@salesforce/label/c.PromoCodeWizard_PP_Search_Label';
import LBL_SearchPlaceholder from '@salesforce/label/c.PromoCodeWizard_PP_SearchPlaceholder';
import LBL_Searching from '@salesforce/label/c.PromoCodeWizard_PP_Searching';
import LBL_SelectedTemplate from '@salesforce/label/c.PromoCodeWizard_PP_SelectedTemplate';

/**
 * Multi-select picker for Specific Products scope. Search filters out inactive products
 * (server-side via PromoCodeService.searchProducts), surfaces "Product Code — Product Name"
 * in result rows, and emits a CSV of Product Codes (NOT names) to the parent so that
 * Specific_Products__c is populated per data-model.md spec.
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
            // We only have the codes on rehydrate — show code as both code and label
            // until the user searches/edits. (Full re-fetch of names is unnecessary for the
            // happy path: edit-after-create is rare due to Lock VR, and on draft edit the
            // staff can re-search to re-select.)
            this.selected = codes.map((c) => ({ code: c, name: c, label: c }));
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
                const takenCodes = new Set(this.selected.map((s) => s.code));
                this.results = (r || []).filter((p) => !takenCodes.has(p.productCode));
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
        if (!code) return; // Specific_Products__c is CSV of Product Codes — skip rows without one
        if (!this.selected.some((s) => s.code === code)) {
            this.selected = [
                ...this.selected,
                { code, name, label: `${code} — ${name}` }
            ];
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
