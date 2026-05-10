import { LightningElement, api } from 'lwc';
import searchProducts from '@salesforce/apex/PromoCodeService.searchProducts';

export default class PromoSpecificProductPicker extends LightningElement {
    @api initialCsv = '';

    searchTerm = '';
    results = [];
    selected = [];
    loading = false;

    connectedCallback() {
        if (this.initialCsv) {
            const names = this.initialCsv
                .split(',')
                .map((s) => s.trim())
                .filter(Boolean);
            this.selected = names.map((n) => ({ name: n, label: n }));
        }
    }

    get hasResults() {
        return this.results && this.results.length > 0;
    }

    get hasSelected() {
        return this.selected.length > 0;
    }

    get selectedCount() {
        return this.selected.length;
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
                const taken = new Set(this.selected.map((s) => s.name));
                this.results = (r || []).filter((p) => !taken.has(p.name));
            })
            .catch(() => {
                this.results = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    addProduct(e) {
        const name = e.currentTarget.dataset.name;
        const code = e.currentTarget.dataset.code;
        if (!this.selected.some((s) => s.name === name)) {
            this.selected = [
                ...this.selected,
                { name, label: code ? `${name} (${code})` : name }
            ];
            this.fireChange();
        }
        this.results = this.results.filter((r) => r.name !== name);
    }

    removeProduct(e) {
        const name = e.target.name;
        this.selected = this.selected.filter((s) => s.name !== name);
        this.fireChange();
    }

    fireChange() {
        const csv = this.selected.map((s) => s.name).join(',');
        this.dispatchEvent(
            new CustomEvent('change', { detail: { csv, count: this.selected.length } })
        );
    }
}
