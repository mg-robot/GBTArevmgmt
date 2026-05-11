import { LightningElement, api, wire } from 'lwc';
import { gql, graphql } from 'lightning/graphql';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class OrderConfirmation extends LightningElement {
    @api orderId;
    order;
    lineItems = [];
    error;
    isLoading = true;

    @wire(graphql, {
        query: gql`
            query getOrderConfirmation($orderId: ID!) {
                uiapi {
                    query {
                        Order(where: { Id: { eq: $orderId } }) {
                            edges {
                                node {
                                    Id
                                    OrderNumber { value }
                                    Status { value }
                                    TotalAmount { value }
                                    GrandTotalAmount { value }
                                    EffectiveDate { value }
                                    Account {
                                        Name { value }
                                    }
                                    BillingStreet { value }
                                    BillingCity { value }
                                    BillingState { value }
                                    BillingPostalCode { value }
                                    BillingCountry { value }
                                }
                            }
                        }
                        OrderItem(where: { OrderId: { eq: $orderId } }) {
                            edges {
                                node {
                                    Id
                                    Quantity { value }
                                    UnitPrice { value }
                                    TotalPrice { value }
                                    ServiceDate { value }
                                    EndDate { value }
                                    Product2 {
                                        Name { value }
                                        Description { value }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        `,
        variables: '$graphqlVariables'
    })
    graphqlQueryResult({ data, errors }) {
        this.isLoading = false;
        if (data) {
            const orderNode = data.uiapi.query.Order.edges[0]?.node;
            if (orderNode) {
                this.order = {
                    Id: orderNode.Id,
                    OrderNumber: orderNode.OrderNumber.value,
                    Status: orderNode.Status.value,
                    TotalAmount: orderNode.TotalAmount.value,
                    GrandTotalAmount: orderNode.GrandTotalAmount.value,
                    EffectiveDate: orderNode.EffectiveDate?.value,
                    Account: { Name: orderNode.Account?.Name?.value },
                    BillingStreet: orderNode.BillingStreet?.value,
                    BillingCity: orderNode.BillingCity?.value,
                    BillingState: orderNode.BillingState?.value,
                    BillingPostalCode: orderNode.BillingPostalCode?.value,
                    BillingCountry: orderNode.BillingCountry?.value
                };
            }
            this.lineItems = data.uiapi.query.OrderItem.edges.map(edge => ({
                Id: edge.node.Id,
                Quantity: edge.node.Quantity.value,
                formattedUnitPrice: this.formatCurrency(edge.node.UnitPrice.value),
                formattedTotalPrice: this.formatCurrency(edge.node.TotalPrice.value),
                formattedServiceDate: this.formatDate(edge.node.ServiceDate?.value),
                formattedEndDate: this.formatDate(edge.node.EndDate?.value),
                Product2: {
                    Name: edge.node.Product2.Name.value,
                    Description: edge.node.Product2.Description?.value
                }
            }));
            this.error = undefined;
        } else if (errors) {
            this.error = errors;
            this.order = undefined;
            this.lineItems = [];
            this.showErrorToast();
        }
    }

    get graphqlVariables() {
        return { orderId: this.orderId };
    }

    get hasLineItems() {
        return this.lineItems && this.lineItems.length > 0;
    }

    get billingAddress() {
        if (!this.order) return '';
        return [
            this.order.BillingStreet,
            this.order.BillingCity,
            this.order.BillingState,
            this.order.BillingPostalCode,
            this.order.BillingCountry
        ].filter(Boolean).join(', ');
    }

    get formattedDate() {
        return this.order?.EffectiveDate
            ? new Date(this.order.EffectiveDate).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })
            : '';
    }

    get formattedSubtotal() {
        return this.formatCurrency(this.order?.TotalAmount);
    }

    get formattedTax() {
        const tax = (this.order?.GrandTotalAmount || 0) - (this.order?.TotalAmount || 0);
        return this.formatCurrency(tax);
    }

    get formattedGrandTotal() {
        return this.formatCurrency(this.order?.GrandTotalAmount);
    }

    formatCurrency(value) {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(value || 0);
    }

    formatDate(dateString) {
        return dateString
            ? new Date(dateString).toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' })
            : '';
    }

    showErrorToast() {
        this.dispatchEvent(new ShowToastEvent({
            title: 'Error loading order',
            message: this.error?.body?.message || 'Unknown error',
            variant: 'error'
        }));
    }
}