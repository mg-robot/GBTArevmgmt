import { LightningElement, api, wire } from 'lwc';
import { gql, graphql, refreshGraphQL } from 'lightning/graphql';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { registerRefreshHandler, unregisterRefreshHandler } from 'lightning/refresh';
import { MessageContext, subscribe, unsubscribe } from 'lightning/messageService';


export default class OrderDetails extends LightningElement {
    @api recordId;
    order;
    error;
    isLoading = true;
    _refreshHandlerID;
    _graphqlResult;
    @wire(MessageContext) messageContext;
    _subscription;

    connectedCallback() {
        // this._refreshHandlerID = registerRefreshHandler(this, this.handleRefresh.bind(this));
        // this._subscription = subscribe(this.messageContext, ORDER_REFRESH_CHANNEL, () => {
        //     refreshGraphQL(this._graphqlResult);
        // });
    }

    disconnectedCallback() {
        // unregisterRefreshHandler(this._refreshHandlerID);
        // unsubscribe(this._subscription);
    }

    handleRefresh() {
        return refreshGraphQL(this._graphqlResult);
    }

    @wire(graphql, {
        query: gql`
            query getOrderDetails($recordId: ID!) {
                uiapi {
                    query {
                        Order(where: { Id: { eq: $recordId } }) {
                            edges {
                                node {
                                    Id
                                    OrderNumber { value }
                                    Status { value }
                                    TotalAmount { value }
                                    EffectiveDate { value }
                                    EndDate { value }
                                    CreatedDate { value }
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
            const orderNode = data.uiapi.query.Order.edges[0]?.node;
            if (orderNode) {
                this.order = {
                    Id: orderNode.Id,
                    OrderNumber: orderNode.OrderNumber.value,
                    Status: orderNode.Status.value,
                    TotalAmount: orderNode.TotalAmount.value,
                    EffectiveDate: orderNode.EffectiveDate.value,
                    EndDate: orderNode.EndDate.value,
                    Account: {
                        Name: orderNode.Account.Name.value
                    },
                    BillingStreet: orderNode.BillingStreet?.value,
                    BillingCity: orderNode.BillingCity?.value,
                    BillingState: orderNode.BillingState?.value,
                    BillingPostalCode: orderNode.BillingPostalCode?.value,
                    BillingCountry: orderNode.BillingCountry?.value
                };
                this.error = undefined;
            }
        } else if (errors) {
            this.error = errors;
            this.order = undefined;
            this.showErrorToast();
        }
    }

    get graphqlVariables() {
        return {
            recordId: this.recordId
        };
    }

    get formattedAmount() {
        return this.order?.TotalAmount
            ? new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(this.order.TotalAmount)
            : '$0.00';
    }

    get formattedStartDate() {
        return this.order?.EffectiveDate
            ? new Date(this.order.EffectiveDate).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })
            : '';
    }

    get formattedEndDate() {
        return this.order?.EndDate
            ? new Date(this.order.EndDate).toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })
            : '';
    }

    get billingAddress() {
        if (!this.order) return '';
        const parts = [
            this.order.BillingStreet,
            this.order.BillingCity,
            this.order.BillingState,
            this.order.BillingPostalCode,
            this.order.BillingCountry
        ].filter(Boolean);
        return parts.join(', ');
    }

    showErrorToast() {
        const evt = new ShowToastEvent({
            title: 'Error loading order',
            message: this.error?.body?.message || 'Unknown error',
            variant: 'error',
        });
        this.dispatchEvent(evt);
    }
}