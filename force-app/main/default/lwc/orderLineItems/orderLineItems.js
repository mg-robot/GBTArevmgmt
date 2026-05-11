import { LightningElement, api, wire } from 'lwc';
import { gql, graphql, refreshGraphQL } from 'lightning/graphql';
import { MessageContext, subscribe, unsubscribe } from 'lightning/messageService';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class OrderLineItems extends LightningElement {
    @api recordId;
    lineItems = [];
    error;
    isLoading = true;
    orderTotalAmount = 0;
    orderTotalTaxAmount = 0;
    orderGrandTotalAmount = 0;
    @wire(MessageContext) messageContext;
    _graphqlResult;
    _subscription;

    @wire(graphql, {
        query: gql`
            query getOrderLineItems($recordId: ID!) {
                uiapi {
                    query {
                        OrderItem(where: { OrderId: { eq: $recordId } }) {
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
                        Order(where: { Id: { eq: $recordId } }) {
                            edges {
                                node {
                                    TotalAmount { value }
                                    TotalTaxAmount { value }
                                    GrandTotalAmount { value }
                                }
                            }
                        }
                    }
                }
            }
        `,
        variables: '$graphqlVariables'
    })
    graphqlQueryResult(result) {
        this._graphqlResult = result;
        const { data, errors } = result;
        this.isLoading = false;
        if (data) {
            this.lineItems = data.uiapi.query.OrderItem.edges.map(edge => ({
                Id: edge.node.Id,
                Quantity: edge.node.Quantity.value,
                UnitPrice: edge.node.UnitPrice.value,
                TotalPrice: edge.node.TotalPrice.value,
                ServiceDate: edge.node.ServiceDate?.value,
                EndDate: edge.node.EndDate?.value,
                Product2: {
                    Name: edge.node.Product2.Name.value,
                    Description: edge.node.Product2.Description?.value
                }
            }));
            const orderEdge = data.uiapi.query.Order.edges[0];
            this.orderTotalAmount = orderEdge?.node.TotalAmount.value ?? 0;
            this.orderTotalTaxAmount = orderEdge?.node.TotalTaxAmount.value ?? 0;
            this.orderGrandTotalAmount = orderEdge?.node.GrandTotalAmount.value ?? 0;
            this.error = undefined;
        } else if (errors) {
            this.error = errors;
            this.lineItems = [];
            this.showErrorToast();
        }
    }

    get graphqlVariables() {
        return {
            recordId: this.recordId
        };
    }

    connectedCallback() {
        // this._subscription = subscribe(this.messageContext, ORDER_REFRESH_CHANNEL, () => {
        //     refreshGraphQL(this._graphqlResult);
        // });
    }

    disconnectedCallback() {
        // unsubscribe(this._subscription);
    }

    get hasLineItems() {
        return this.lineItems && this.lineItems.length > 0;
    }

    get formattedSubtotal() {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(this.orderTotalAmount);
    }

    get formattedTax() {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(this.orderTotalTaxAmount);
    }

    get formattedTotal() {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(this.orderGrandTotalAmount);
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
        const evt = new ShowToastEvent({
            title: 'Error loading line items',
            message: this.error?.body?.message || 'Unknown error',
            variant: 'error',
        });
        this.dispatchEvent(evt);
    }
}