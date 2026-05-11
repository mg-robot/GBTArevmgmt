import { LightningElement, api, wire, track } from 'lwc';
import { CurrentPageReference, NavigationMixin } from 'lightning/navigation';
import { CartSummaryAdapter } from 'commerce/cartApi';
import basePath from '@salesforce/community/basePath';
import getNavigationMenuItems from '@salesforce/apex/NavigationMenuItemsController.getNavigationMenuItems';
import isGuestUser from '@salesforce/user/isGuest';

export default class GbtaHeader extends NavigationMixin(LightningElement) {
    @api menuName;
    @api logoUrl;
    @api logoAlt = 'GBTA';
    @api searchPageApiName;
    @api cartPageApiName;
    @api wishlistPageApiName;
    @api languageLabel;
    @api languagePageApiName;

    @track menuItems = [];
    @track showHamburgerMenu = false;
    @track cartItemCount = 0;

    basePath = basePath;
    publishedState;

    @wire(CurrentPageReference)
    setCurrentPageReference(currentPageReference) {
        const app = currentPageReference?.state?.app;
        this.publishedState = app === 'commeditor' ? 'Draft' : 'Live';
    }

    @wire(getNavigationMenuItems, {
        menuName: '$menuName',
        publishedState: '$publishedState'
    })
    wiredMenuItems({ error, data }) {
        if (data) {
            const filtered = data
                .map((item, index) => ({
                    id: index,
                    label: item.Label,
                    target: item.Target,
                    type: item.Type,
                    defaultListViewId: item.DefaultListViewId,
                    accessRestriction: item.AccessRestriction,
                    computedHref: '#',
                    pageReference: this.buildPageReference(item)
                }))
                .filter(
                    (item) =>
                        item.accessRestriction === 'None' ||
                        (item.accessRestriction === 'LoginRequired' && !isGuestUser)
                );
            this.generateUrls(filtered).then((items) => {
                this.menuItems = items;
            });
        } else if (error) {
            console.error('Header navigation menu error:', JSON.stringify(error));
        }
    }

    @wire(CartSummaryAdapter)
    setCartSummary({ data }) {
        if (data) {
            this.cartItemCount = data.totalProductCount ?? 0;
        }
    }

    async generateUrls(items) {
        return Promise.all(
            items.map(async (item) => {
                if (item.pageReference) {
                    try {
                        item.computedHref = await this[NavigationMixin.GenerateUrl](
                            item.pageReference
                        );
                    } catch (e) {
                        // keep '#' fallback
                    }
                }
                return item;
            })
        );
    }

    buildPageReference(item) {
        const { Type: type, Target: target, DefaultListViewId: defaultListViewId } = item;
        if (type === 'SalesforceObject') {
            return {
                type: 'standard__objectPage',
                attributes: { objectApiName: target },
                state: { filterName: defaultListViewId }
            };
        }
        if (type === 'InternalLink') {
            return {
                type: 'standard__webPage',
                attributes: { url: basePath + target }
            };
        }
        if (type === 'ExternalLink') {
            return {
                type: 'standard__webPage',
                attributes: { url: target }
            };
        }
        return null;
    }

    get hasCartItems() {
        return this.cartItemCount > 0;
    }

    get cartAriaLabel() {
        const count = this.cartItemCount;
        return count > 0
            ? `Shopping cart, ${count} item${count !== 1 ? 's' : ''}`
            : 'Shopping cart';
    }

    handleHamburgerOpen() {
        this.showHamburgerMenu = true;
    }

    handleHamburgerClose() {
        this.showHamburgerMenu = false;
    }

    handleSearchClick() {
        if (this.searchPageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.searchPageApiName }
            });
        }
    }

    handleCartClick() {
        if (this.cartPageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.cartPageApiName }
            });
        }
    }

    handleWishlistClick() {
        if (this.wishlistPageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.wishlistPageApiName }
            });
        }
    }

    handleLanguageClick() {
        if (this.languagePageApiName) {
            this[NavigationMixin.Navigate]({
                type: 'comm__namedPage',
                attributes: { name: this.languagePageApiName }
            });
        }
    }
}