'use client';
import {useEffect} from 'react';
import {Button} from '@/components/ui/button';
export default function ErrorPage({error,reset}:{error:Error&{digest?:string};reset:()=>void}){useEffect(()=>{console.error(error)},[error]);return <div className="page-shell error-page"><span className="eyebrow">Something slipped</span><h1>The page could not settle into place.</h1><p>Your local drafts are untouched.</p><Button size="lg" onClick={reset}>Try again</Button></div>;}
