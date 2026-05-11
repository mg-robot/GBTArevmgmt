import { LightningElement, api, wire } from 'lwc';
import { MessageContext, publish } from 'lightning/messageService';
//import ORDER_REFRESH_CHANNEL from '@salesforce/messageChannel/OrderRefreshMessageChannel__c';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getProducts from '@salesforce/apex/ProductCatalogController.getProducts';
import addProductsToOrder from '@salesforce/apex/ProductCatalogController.addProductsToOrder';
import getOrderLineItems from '@salesforce/apex/ProductCatalogController.getOrderLineItems';
import removeOrderItems from '@salesforce/apex/ProductCatalogController.removeOrderItems';

export default class OrderProductSelector extends LightningElement {
    @api recordId;
    @wire(MessageContext) messageContext;

    showModal = false;
    activeTab = 'add';
    products = [];
    lineItems = [];
    selectedItemIds = new Set();
    isLoading = false;
    error;

    // ── Tab getters ──────────────────────────────────────────────
    get isAddTab()    { return this.activeTab === 'add'; }
    get isRemoveTab() { return this.activeTab === 'remove'; }
    get addTabClass()    { return 'tab-btn' + (this.isAddTab    ? ' active' : ''); }
    get removeTabClass() { return 'tab-btn' + (this.isRemoveTab ? ' active' : ''); }

    // ── Add-tab getters ──────────────────────────────────────────
    get hasProducts() { return this.products && this.products.length > 0; }

    get selectedProducts() { return this.products.filter(p => p.isSelected); }
    get hasSelectedProducts() { return this.selectedProducts.length > 0; }
    get selectedProductCount() { return this.selectedProducts.length; }

    // ── Remove-tab getters ───────────────────────────────────────
    get hasLineItems() { return this.lineItems && this.lineItems.length > 0; }
    get hasSelectedItems() { return this.selectedItemIds.size > 0; }
    get selectedItemCount() { return this.selectedItemIds.size; }

    // ── Badge label for header ───────────────────────────────────
    get badgeCount() {
        return this.isAddTab ? this.selectedProductCount : this.selectedItemCount;
    }
    get showBadge() {
        return this.isAddTab ? this.hasSelectedProducts : this.hasSelectedItems;
    }

    // ── Modal open / close ───────────────────────────────────────
    handleOpenModal() {
        this.showModal = true;
        this.activeTab = 'add';
        this.isLoading = true;
        this.error = undefined;
        Promise.allSettled([
            getProducts({ orderId: this.recordId }),
            getOrderLineItems({ orderId: this.recordId })
        ])
            .then(([productsResult, itemsResult]) => {
                if (productsResult.status === 'fulfilled') {
                    const products = productsResult.value;
                    this.products = products.map(p => {
                        const defaultOption = p.sellingModelOptions?.find(o => o.isDefault) || p.sellingModelOptions?.[0];
                        return {
                            ...p,
                            isSelected: false,
                            formattedPrice: this.formatCurrency(p.unitPrice),
                            selectedSellingModelId: defaultOption?.sellingModelId ?? null,
                            sellingModelOptions: (p.sellingModelOptions || []).map(o => ({
                                ...o,
                                radioValue: o.sellingModelId,
                                radioLabel: o.name
                            }))
                        };
                    });
                } else {
                    this.showErrorToast(productsResult.reason?.body?.message || 'Failed to load products');
                }

                if (itemsResult.status === 'fulfilled') {
                    this.lineItems = itemsResult.value.map(i => ({
                        ...i,
                        isSelected: false,
                        formattedUnitPrice:  this.formatCurrency(i.unitPrice),
                        formattedTotalPrice: this.formatCurrency(i.totalPrice)
                    }));
                } else {
                    this.showErrorToast(itemsResult.reason?.body?.message || 'Failed to load line items');
                }

                this.isLoading = false;
            });
    }

    handleCancel() {
        this.showModal = false;
        this.products = [];
        this.lineItems = [];
        this.selectedItemIds.clear();
        this.activeTab = 'add';
    }

    // ── Tab switching ────────────────────────────────────────────
    handleTabChange(event) {
        this.activeTab = event.target.dataset.tab;
    }

    // ── Add-products handlers ────────────────────────────────────
    handleCheckboxChange(event) {
        const productId = event.target.dataset.productId;
        const isChecked = event.target.checked;
        this.products = this.products.map(p =>
            p.id === productId ? { ...p, isSelected: isChecked } : p
        );
    }

    handleSellingModelChange(event) {
        const productId = event.target.dataset.productId;
        const sellingModelId = event.target.value;
        this.products = this.products.map(p =>
            p.id === productId ? { ...p, selectedSellingModelId: sellingModelId } : p
        );
    }

    handleAddToOrder() {
        if (!this.hasSelectedProducts) {
            this.showToast('Please select at least one product', 'warning');
            return;
        }
        const selected = this.selectedProducts;
        const product2Ids   = selected.map(p => p.id);
        const sellingModelIds = selected.map(p => p.selectedSellingModelId);

        this.isLoading = true;
        addProductsToOrder({ orderId: this.recordId, product2Ids, sellingModelIds })
            .then(() => {
                this.isLoading = false;
                this.handleCancel();
                this.showToast('Products added to order successfully', 'success');
                //publish(this.messageContext, ORDER_REFRESH_CHANNEL, {});
            })
            .catch(error => {
                this.isLoading = false;
                this.showErrorToast(error?.body?.message || 'Failed to add products to order');
            });
    }

    // ── Remove-items handlers ────────────────────────────────────
    handleLineItemCheckboxChange(event) {
        const itemId = event.target.dataset.itemId;
        const isChecked = event.target.checked;
        if (isChecked) {
            this.selectedItemIds.add(itemId);
        } else {
            this.selectedItemIds.delete(itemId);
        }
        this.lineItems = this.lineItems.map(i => ({
            ...i,
            isSelected: this.selectedItemIds.has(i.id)
        }));
    }

    handleRemoveItems() {
        if (!this.hasSelectedItems) {
            this.showToast('Please select at least one item to remove', 'warning');
            return;
        }
        this.isLoading = true;
        removeOrderItems({ orderId: this.recordId, orderItemIds: Array.from(this.selectedItemIds) })
            .then(() => {
                this.isLoading = false;
                this.handleCancel();
                this.showToast('Items removed successfully', 'success');
               // publish(this.messageContext, ORDER_REFRESH_CHANNEL, {});
            })
            .catch(error => {
                this.isLoading = false;
                this.showErrorToast(error?.body?.message || 'Failed to remove items');
            });
    }

    // ── Utilities ────────────────────────────────────────────────
    formatCurrency(value) {
        return value != null
            ? new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value)
            : 'N/A';
    }

    showToast(message, variant) {
        this.dispatchEvent(new ShowToastEvent({ message, variant }));
    }

    showErrorToast(message) {
        this.dispatchEvent(new ShowToastEvent({ title: 'Error', message, variant: 'error' }));
    }
}