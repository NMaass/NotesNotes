import type {MetadataRoute} from 'next';
export default function manifest():MetadataRoute.Manifest{return{name:'Resonote',short_name:'Resonote',description:'A journal for close listening.',start_url:'/',display:'standalone',background_color:'#101113',theme_color:'#101113',icons:[{src:'/logo-mark.svg',sizes:'any',type:'image/svg+xml'}]};}
